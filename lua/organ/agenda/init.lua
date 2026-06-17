-- Agenda buffer for organ.nvim.
--
-- Orchestrator: buffer machinery (open/refresh) + bulk ops. The pieces
-- live in focused submodules:
--   * agenda/span.lua       view-spec normalization + date-window resolution
--   * agenda/navigate.lua   period navigation (shift / reset / set window)
--   * agenda/views.lua      view entry points + dispatcher + command table
--   * agenda/collect.lua    per-block record collection + annotation
--   * agenda/render.lua     records -> { lines, extmarks, line_index, block_starts }
--   * agenda/format.lua     record -> display line (prefix mini-format-language)
--   * agenda/dates.lua      date/time helpers + deterministic clock override
--   * agenda/state.lua      per-buffer view state stored in vim.b
--   * agenda/keymaps.lua    buffer-local keybindings
--   * agenda/highlights.lua, agenda/groups.lua

local M = {}

local obuf = require("organ.buf")
local highlights = require("organ.agenda.highlights")
local dates = require("organ.agenda.dates")
local format = require("organ.agenda.format")
local render = require("organ.agenda.render")
local collect = require("organ.agenda.collect")
local vstate = require("organ.agenda.state")
local keymaps = require("organ.agenda.keymaps")
local span = require("organ.agenda.span")
local navigate = require("organ.agenda.navigate")
local views = require("organ.agenda.views")

-- Public pure helpers.

M.resolve_span = span.resolve_span
M.normalize_view = span.normalize_view
M.add_entry_path_ok = span.add_entry_path_ok

-- Agenda fold model — three nesting levels for the multi-block view:
--   1. View header (`Week-agenda (W19):`) sits at level 0 (never folded).
--   2. Block separators (`════════════════`) start a level-1 fold.
--   3. Day headers (`Monday      4 May 2026 W19`) start a level-2 fold
--      so users can collapse a single day inside a multi-day block
--      while keeping siblings open.
-- All other lines inherit the most-recent header's level.
local function _is_block_sep(line)
  return line:sub(1, 6) == "══" or line:sub(1, 6) == "──" or line:sub(1, 2) == "=="
end

local function _is_day_header(line)
  return line:match("^%a+%s+%d+%s+%a+%s+%d%d%d%d") ~= nil
end

function M.foldexpr(lnum)
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  -- Block separator: level-1 fold start.  Glyph variants: `══`
  -- (default), `──`, or ASCII `==` fallback.  Each unicode glyph is
  -- 3 bytes so 2 of them = 6 bytes; ASCII = 2 bytes.
  if _is_block_sep(line) then
    return ">1"
  end
  -- Day header: `Monday      4 May 2026 …` shape.  Level-2 fold start
  -- so each day collapses individually.
  if _is_day_header(line) then
    return ">2"
  end
  -- View header line (`Week-agenda (W19):`) — level 0, never folded.
  if line:match("^%a[%w%-]*%-agenda%s*%(W%d") then
    return "0"
  end
  -- The line immediately BEFORE a day header drops to level 1 so the
  -- next `>2` is a level-1→level-2 transition; without this, vim
  -- renders adjacent level-2 fold starts as one continuous fold and
  -- statuscolumn (which compares foldlevel against the prior line)
  -- only draws a chevron on the first day header.
  local next_line = vim.api.nvim_buf_get_lines(0, lnum, lnum + 1, false)[1]
  if next_line and _is_day_header(next_line) then
    return "1"
  end
  return "="
end

function M.render(blocks_with_rows, opts)
  -- Re-apply user-supplied keyword_faces / tag faces on every render
  -- so config changes take effect without a plugin reload.  Static
  -- defaults are registered only once, guarded inside agenda.highlights.
  M._register_highlights()
  return render.render(blocks_with_rows, opts)
end

-- Buffer machinery: open, refresh, filetype, event-driven refresh.

local NS = vim.api.nvim_create_namespace("organ-agenda")

-- Public accessor so tests and keymaps can read decoded state (with integer
-- block_starts keys) without accessing vim.b directly.
M.buf_state = vstate.get

-- Public bulk-delete / undo / redo primitives.
--
-- The gB action menu and u / <C-r> keymaps in the agenda buffer
-- delegate to these. Extracting them keeps the keymap closures small
-- and lets tests drive the full round-trip without going through
-- vim.ui.select.
--
-- A "snapshot" is a list of { file = bufnr, lnum = N, lines = {...} }
-- describing one or more subtrees that were cut. delete_history
-- (LIFO) holds these so `u` can restore them; redo_history holds
-- the snapshots `u` undid so `<C-r>` can re-cut.

-- Cut the subtrees described by `marked_rows` (each must have file_path
-- + line_start, OR _source_bufnr + _source_lnum) and append the snapshot
-- to bufnr's delete_history. Invalidates the redo_history (vim
-- convention: new edit drops redo branch). Returns the snapshot.
function M.bulk_delete_apply(bufnr, marked_rows)
  local structure = require("organ.structure")
  local clipboard = require("organ.clipboard")
  local snapshot = {}
  for _, r in ipairs(marked_rows) do
    local target = r._source_bufnr or vim.fn.bufadd(r.file_path)
    vim.fn.bufload(target)
    local lnum = r._source_lnum or ((r.line_start or 0) + 1)
    local hl = structure._find_containing_headline(target, lnum)
    if hl then
      local subtree_end = structure._subtree_end(target, hl)
      local snap_lines = vim.api.nvim_buf_get_lines(target, hl.line - 1, subtree_end, false)
      snapshot[#snapshot + 1] = { file = target, lnum = hl.line, lines = snap_lines }
    end
  end
  table.sort(snapshot, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum > b.lnum
  end)
  for _, s in ipairs(snapshot) do
    pcall(clipboard.cut, s.file, s.lnum)
  end
  local hstate = vstate.get(bufnr) or {}
  hstate.delete_history = hstate.delete_history or {}
  hstate.delete_history[#hstate.delete_history + 1] = snapshot
  hstate.redo_history = {}
  vstate.set(bufnr, hstate)
  return snapshot
end

-- Pop the top of bufnr's delete_history and re-insert each subtree at
-- its captured (file, lnum). Pushes onto redo_history. Returns the
-- snapshot, or nil when the stack is empty.
function M.undo_last_delete(bufnr)
  local state = vstate.get(bufnr) or {}
  local stack = state.delete_history or {}
  if #stack == 0 then
    return nil
  end
  local snap = stack[#stack]
  stack[#stack] = nil
  table.sort(snap, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum < b.lnum
  end)
  for _, s in ipairs(snap) do
    if vim.api.nvim_buf_is_valid(s.file) then
      pcall(obuf.set_lines, s.file, s.lnum - 1, s.lnum - 1, s.lines)
    end
  end
  state.delete_history = stack
  state.redo_history = state.redo_history or {}
  state.redo_history[#state.redo_history + 1] = snap
  vstate.set(bufnr, state)
  return snap
end

-- Pop the top of bufnr's redo_history and re-cut. Pushes back onto
-- delete_history. Returns the snapshot or nil.
function M.redo_last_delete(bufnr)
  local state = vstate.get(bufnr) or {}
  local stack = state.redo_history or {}
  if #stack == 0 then
    return nil
  end
  local snap = stack[#stack]
  stack[#stack] = nil
  local plan = {}
  for _, s in ipairs(snap) do
    plan[#plan + 1] = s
  end
  table.sort(plan, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum > b.lnum
  end)
  for _, s in ipairs(plan) do
    if vim.api.nvim_buf_is_valid(s.file) then
      pcall(obuf.set_lines, s.file, s.lnum - 1, s.lnum - 1 + #s.lines, {})
    end
  end
  state.redo_history = stack
  state.delete_history = state.delete_history or {}
  state.delete_history[#state.delete_history + 1] = snap
  vstate.set(bufnr, state)
  return snap
end

-- Apply extmarks to a buffer. If `range_start` and `range_end_exclusive`
-- are given (0-based row numbers), only clear+re-apply marks in that
-- row range and leave marks outside it alone — avoids the full-buffer
-- repaint flicker that hit on every `t` toggle. Pass nil for both to
-- fall back to clear-all + re-add-all (used when line count changed).
-- Build the extmark-opts table for a single mark.  Default form is a
-- highlighted byte range (`{ end_col, hl_group }`); when the 2nd
-- element is the literal `"_virt"` sentinel, the 5th element of the
-- tuple is a full opts table passed through verbatim — used for
-- right-align virt-text (tag column) which is decorative, not a
-- buffer slice.
local function mark_opts(mk)
  local hl, col_end = mk[2], mk[4]
  if hl == "_virt" then
    -- Sentinel: pass-through opts table.  Caller built the full
    -- extmark spec including virt_text / virt_text_pos / etc.
    return mk[5] or {}
  end
  return { end_col = col_end, hl_group = hl }
end

local function apply_extmarks(bufnr, extmarks, range_start, range_end_exclusive)
  if range_start ~= nil and range_end_exclusive ~= nil then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, range_start, range_end_exclusive)
    for _, mk in ipairs(extmarks) do
      local row = mk[1] - 1 -- extmark rows are 0-based
      if row >= range_start and row < range_end_exclusive then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, mk[3], mark_opts(mk))
      end
    end
  else
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    for _, mk in ipairs(extmarks) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, mk[1] - 1, mk[3], mark_opts(mk))
    end
  end
end

-- Forwarder for external callers (refile, tests). run_query resolves
-- file specs through collect's own table, so replacing this entry does
-- not affect queries.
M.resolve_agenda_files = collect.resolve_agenda_files

function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local state = vstate.get(bufnr)
  local view = state.view or { blocks = {} }

  -- Capture the headline ID under cursor BEFORE refresh so we can restore
  -- the cursor to the same headline after re-render. Without this, sorting
  -- comparators that include todo_state/priority make the cursor jump to
  -- a random row whenever the user toggles a TODO state.
  local prev_id
  local prev_winid
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      prev_winid = w
      break
    end
  end
  if prev_winid and state.line_index then
    local prev_lnum = vim.api.nvim_win_get_cursor(prev_winid)[1]
    local row = state.line_index[prev_lnum]
    if row then
      prev_id = row.id
    end
  end

  -- Thread per-buffer log_mode flag into each block so run_query
  -- knows whether to inject CLOSED rows.  We mutate the block in
  -- place rather than copying; clear afterwards so a stale flag from
  -- a previous toggle doesn't leak across non-buffer renders.
  local log_cfg = ((require("organ.buf_config").read(nil, "agenda") or {}).log_mode or {})
  local log_active = state.log_mode
  if log_active == nil then
    log_active = log_cfg.on_start == true
  end
  local blocks_with_rows = {}
  for _, block in ipairs(view.blocks) do
    block._log_mode_active = log_active
    block.log_mode_items = log_cfg.items or { "closed", "clock" }
    local ok, rows = pcall(collect.run_query, block)
    block._log_mode_active = nil
    if ok then
      blocks_with_rows[#blocks_with_rows + 1] = { block = block, rows = rows }
    else
      blocks_with_rows[#blocks_with_rows + 1] = {
        block = block,
        rows = {},
        query_error = tostring(rows),
      }
    end
  end

  -- Effort filter (set by the `e` keymap). Applies after run_query so
  -- it composes with all other filters and is cheap to clear.
  if state.effort_filter and state.effort_filter ~= "" then
    local effort = require("organ.effort")
    local pred = effort.parse_filter(state.effort_filter)
    if pred then
      for _, br in ipairs(blocks_with_rows) do
        local kept = {}
        for _, r in ipairs(br.rows) do
          local mins = effort.row_effort_minutes(r)
          if pred(mins) then
            kept[#kept + 1] = r
          end
        end
        br.rows = kept
      end
    end
  end

  -- Per-buffer toggle state lifted into the render opts so M.render
  -- doesn't have to reach into vim.b for every entry-text decision.
  local rstate = vstate.get(bufnr)
  local out = M.render(blocks_with_rows, {
    now = dates.today_iso(),
    entry_text = rstate.entry_text,
  })

  -- Buffer-only UX additions: empty-state hint + footer keymap reference.
  -- Kept out of M.render so the pure renderer stays predictable for tests.
  local cfg_agenda = (require("organ.buf_config").read(nil, "agenda") or {})
  local total_rows = 0
  for _, br in ipairs(blocks_with_rows) do
    total_rows = total_rows + #br.rows
  end
  if total_rows == 0 then
    if #out.lines > 0 then
      out.lines[#out.lines + 1] = ""
    end
    local empty = render.empty_state_lines()
    local empty_start = #out.lines + 1
    for _, l in ipairs(empty) do
      out.lines[#out.lines + 1] = l
    end
    for i = empty_start, #out.lines do
      out.extmarks[#out.extmarks + 1] = { i, "Comment", 0, #(out.lines[i] or "") }
    end
  end
  -- Clock-report mode (toggled via gR). When on, append a clocktable
  -- showing total clocked time per headline within the visible date
  -- window. Mirrors Emacs `R` in agenda buffer.
  do
    local agenda_state = vstate.decode(vim.b[bufnr].organ_agenda) or {}
    -- `agenda.clockreport_mode = true` (Emacs `org-agenda-clockreport-
    -- mode`) starts each agenda buffer with the clock report visible
    -- (default off; `gR` toggles per-buffer).
    local clock_default = (require("organ.buf_config").read(nil, "agenda") or {}).clockreport_mode
      == true
    local show_clock_report = agenda_state.clock_report_mode
    if show_clock_report == nil then
      show_clock_report = clock_default
    end
    if show_clock_report then
      local first
      for _, br in ipairs(blocks_with_rows) do
        if br.block and br.block.from then
          first = br.block
          break
        end
      end
      if first then
        local query = require("organ.query")
        local from_iso = (query.parse_date and query.parse_date(first.from)) or first.from
        local to_iso = (query.parse_date and query.parse_date(first.to or first.from))
          or (first.to or first.from)
        local rows = {}
        local ok_q, entries = pcall(query.clock_entries, {
          from = from_iso,
          to = to_iso,
          group_by = "headline",
        })
        if ok_q and entries then
          rows = entries
        end
        if #out.lines > 0 then
          out.lines[#out.lines + 1] = ""
        end
        local hdr = string.format("Clock report (%s → %s):", from_iso, to_iso)
        out.lines[#out.lines + 1] = hdr
        out.extmarks[#out.extmarks + 1] = { #out.lines, "@organ.agenda.block_header", 0, #hdr }
        local report_start = #out.lines + 1
        for _, l in ipairs(require("organ.clock.report").render(rows, {})) do
          out.lines[#out.lines + 1] = l
        end
        for i = report_start, #out.lines do
          out.extmarks[#out.extmarks + 1] = { i, "@organ.agenda.title", 0, #(out.lines[i] or "") }
        end
      end
    end
  end

  -- Buffer footer with keymap hints. Default ON because we don't install
  -- a winbar/statusline by default (no-surprises rule), and without any
  -- chrome the keymaps would be invisible. Set `agenda.footer = false`
  -- to suppress (typically when you've opted into `agenda.statusline`
  -- and don't need both).
  if cfg_agenda.footer ~= false then
    if #out.lines > 0 then
      out.lines[#out.lines + 1] = ""
    end
    local footer_start = #out.lines + 1
    for _, l in ipairs(render.FOOTER_LINES) do
      out.lines[#out.lines + 1] = l
    end
    for i = footer_start, #out.lines do
      out.extmarks[#out.extmarks + 1] = { i, "Comment", 0, #(out.lines[i] or "") }
    end
  end

  vim.bo[bufnr].modifiable = true
  -- Incremental update: replace only the changed line range AND only
  -- re-apply extmarks in that range. Full-buffer replacement OR full
  -- extmark clear-and-reapply both caused visible flicker on every
  -- `t` toggle — only one headline actually changed, but the entire
  -- buffer was being repainted.
  local old_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n_old, n_new = #old_lines, #out.lines
  local extmark_range_start, extmark_range_end
  local content_changed = false
  if n_old == n_new then
    local prefix = 0
    while prefix < n_old and old_lines[prefix + 1] == out.lines[prefix + 1] do
      prefix = prefix + 1
    end
    if prefix == n_old then
      -- Buffer text identical — skip both line write AND extmark touch.
      content_changed = false
    else
      local suffix = 0
      while suffix < (n_old - prefix) and old_lines[n_old - suffix] == out.lines[n_new - suffix] do
        suffix = suffix + 1
      end
      obuf.set_lines(
        bufnr,
        prefix,
        n_old - suffix,
        vim.list_slice(out.lines, prefix + 1, n_new - suffix)
      )
      extmark_range_start = prefix
      extmark_range_end = n_new - suffix
      content_changed = true
    end
  else
    -- Line count changed: full replace + full extmark refresh.
    obuf.set_lines(bufnr, 0, -1, out.lines)
    content_changed = true -- full refresh path
  end
  vim.bo[bufnr].modifiable = false
  if content_changed then
    apply_extmarks(bufnr, out.extmarks, extmark_range_start, extmark_range_end)
  end

  state.last_refresh_ts = os.time()
  state.line_index = out.line_index
  state.block_starts = out.block_starts
  vstate.set(bufnr, state)

  -- Cursor follow: locate the previously-focused headline in the new
  -- line_index and move cursor there. Sorting comparators (priority,
  -- todo_state, etc.) frequently shuffle row positions on `t` toggles —
  -- without this the cursor would jump to whatever row landed at the old
  -- line number, which is jarring.
  if prev_id and prev_winid and vim.api.nvim_win_is_valid(prev_winid) then
    for lnum, row in pairs(out.line_index) do
      if row.id == prev_id then
        local total = vim.api.nvim_buf_line_count(bufnr)
        local target = math.min(lnum, total)
        pcall(vim.api.nvim_win_set_cursor, prev_winid, { target, 0 })
        return
      end
    end
    -- Headline disappeared (e.g. its TODO filter no longer matches
    -- after the cycle). Leave cursor where it was, clamped to buffer.
    local prev_lnum = vim.api.nvim_win_get_cursor(prev_winid)[1]
    local total = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, prev_winid, { math.min(prev_lnum, total), 0 })
  end
end

-- Period navigation; agenda/keymaps dispatches these via the injected
-- agenda table.
M.shift_period = navigate.shift_period
M.reset_today = navigate.reset_today
M.set_window = navigate.set_window

-- Sticky agenda registry: { [view_name] = bufnr }. Opening the same
-- view twice (e.g. user runs :Org agenda day twice) reuses the existing
-- buffer instead of creating a duplicate. Set agenda.sticky = false in
-- config to disable; default is on (matches Emacs `org-agenda-sticky`).
M._sticky = M._sticky or {}

-- Build a human-readable buffer name from view_name + resolved dates.
-- The "organ-agenda://" prefix keeps nvim from treating the name as a
-- relative file path; the body identifies the view at a glance:
--   "Day 2026-05-05"      view_name == "day"
--   "Week 2026-W19"       view_name == "week", clean ISO week
--   "Week 2026-W19-W20"   view_name == "week", spans two ISO weeks
--   "Todos"               view_name == "todos"
--   "Tag: <q>"            view_name like "tags:<q>"
--   "Search: <q>"         view_name like "search:<q>"
--   "Agenda: <name>"      any other named view
--   "Agenda"              no view_name
local function format_buf_name(view, view_name)
  local q = require("organ.query")
  local function as_iso(s)
    if not s then
      return nil
    end
    return (q.parse_date and q.parse_date(s)) or s
  end
  local first = view.blocks and view.blocks[1] or {}
  local body
  if view_name == "day" then
    body = "Day " .. (as_iso(first.from) or "?")
  elseif view_name == "week" then
    local from_iso = as_iso(first.from)
    local to_iso = as_iso(first.to or first.from)
    local from_ts = from_iso and dates.iso_to_ts(from_iso)
    local to_ts = to_iso and dates.iso_to_ts(to_iso)
    if from_ts and to_ts then
      local fy = os.date("%Y", from_ts)
      local fw = dates.iso_week_of(from_ts)
      local tw = dates.iso_week_of(to_ts)
      if tw == fw then
        body = string.format("Week %s-W%02d", fy, fw)
      else
        body = string.format("Week %s-W%02d-W%02d", fy, fw, tw)
      end
    else
      body = "Week " .. (from_iso or "?")
    end
  elseif view_name == "todos" then
    body = "Todos"
  elseif view_name and view_name:match("^tags:") then
    body = "Tag: " .. view_name:sub(6)
  elseif view_name and view_name:match("^search:") then
    body = "Search: " .. view_name:sub(8)
  elseif view_name and view_name ~= "" and view_name ~= "default" then
    body = "Agenda: " .. view_name
  else
    body = "Agenda"
  end
  return "organ-agenda://" .. body
end

-- Apply `base` as the buffer name; on collision with another buffer,
-- retry as "base (2)", "base (3)", ...  Same-name conflicts arise
-- when sticky=false and the user re-opens the same view, or when
-- two distinct views happen to render to the same human form.
local function set_unique_buf_name(bufnr, base)
  local function name_taken(name)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= bufnr and vim.api.nvim_buf_is_valid(b) then
        if vim.api.nvim_buf_get_name(b) == name then
          return true
        end
      end
    end
    return false
  end
  if not name_taken(base) then
    vim.api.nvim_buf_set_name(bufnr, base)
    return
  end
  for i = 2, 99 do
    local cand = string.format("%s (%d)", base, i)
    if not name_taken(cand) then
      vim.api.nvim_buf_set_name(bufnr, cand)
      return
    end
  end
  -- Bufnr-suffix fallback if we somehow hit 99 collisions.
  vim.api.nvim_buf_set_name(bufnr, string.format("%s [%d]", base, bufnr))
end

-- Exposed for tests; call sites stay local.
M._format_buf_name = format_buf_name

function M.open(view_opts, view_name)
  highlights.register()

  -- First-run safety net: if the DB has zero indexed files AND the
  -- user has a real org_dir, trigger a background scan and tell them.
  -- Otherwise the agenda silently shows nothing useful, which masquerades
  -- as a parser/filter bug — Emacs's agenda always re-reads
  -- `org-agenda-files` on open.  We don't wait for the scan; the user
  -- can `r`-refresh once the queue drains.  We probe the DB directly
  -- (`indexer.files_count`) instead of trusting `_last_status.last_file`,
  -- which is session-local state that resets on every nvim restart.
  do
    local organ = require("organ")
    local org_dir = organ.config and require("organ.buf_config").read(nil, "org_dir")
    local indexed = 0
    local rt_ok, rt = pcall(require, "organ.runtime")
    if rt_ok then
      local h_ok, h = pcall(rt.db)
      if h_ok and h then
        local idx_ok, idx = pcall(require, "organ.indexer")
        if idx_ok and idx.files_count then
          indexed = idx.files_count(h)
        end
      end
    end
    if
      indexed == 0
      and type(org_dir) == "string"
      and org_dir ~= ""
      and vim.fn.isdirectory(vim.fn.expand(org_dir)) == 1
    then
      require("organ.notify").info(
        "organ: index is empty — scanning "
          .. org_dir
          .. " in background (refresh agenda with `r` when done)"
      )
      pcall(organ._start_scan)
    end
  end

  local view, err = M.normalize_view(view_opts, view_name)
  if not view then
    require("organ.notify").error(err)
    return nil
  end

  local default_lf = (require("organ.buf_config").read(nil, "agenda") or {}).line_format
  if default_lf then
    for _, block in ipairs(view.blocks) do
      if block.line_format == nil then
        block.line_format = default_lf
      end
    end
  end

  -- Reuse an existing buffer for this view name (sticky agenda). The
  -- buffer keeps its scroll position, fold state, and bulk_marked set
  -- across re-opens. New view config overwrites the stored view so a
  -- changed period / title_match takes effect on next refresh.
  local sticky_on = ((require("organ.buf_config").read(nil, "agenda") or {}).sticky ~= false)
  local sticky_key = view_name or "default"
  if sticky_on and M._sticky[sticky_key] then
    local existing = M._sticky[sticky_key]
    if vim.api.nvim_buf_is_valid(existing) then
      local state = vstate.decode(vim.b[existing].organ_agenda) or {}
      state.view = view
      state.view_name = view_name or "default"
      local first = view.blocks[1] or {}
      if first.from then
        state.window = { from = first.from, to = first.to }
      end
      vim.b[existing].organ_agenda = vstate.encode(state)
      -- Refresh the buffer name in case the view's resolved date
      -- changed (e.g. "day" view kept across midnight).
      local desired = format_buf_name(view, view_name)
      if vim.api.nvim_buf_get_name(existing) ~= desired then
        set_unique_buf_name(existing, desired)
      end
      vim.api.nvim_set_current_buf(existing)
      M.refresh(existing)
      return existing
    else
      M._sticky[sticky_key] = nil
    end
  end

  local bufnr = vim.api.nvim_create_buf(true, true)
  set_unique_buf_name(bufnr, format_buf_name(view, view_name))
  vim.bo[bufnr].filetype = "organ-agenda"
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = false
  if sticky_on then
    M._sticky[sticky_key] = bufnr
  end

  -- Stash the view kind / window / name on the buffer so the statusline
  -- elements (`organ.statusline`) and lualine components can read them.
  local first = view.blocks[1] or {}
  local window
  if first.from then
    window = { from = first.from, to = first.to }
  end
  -- Honor on_start defaults so users who always want previews / log
  -- mode don't have to press the toggle after every open.
  local et_cfg = ((require("organ.buf_config").read(nil, "agenda") or {}).entry_text or {})
  local log_cfg_init = ((require("organ.buf_config").read(nil, "agenda") or {}).log_mode or {})
  vstate.set(bufnr, {
    view = view,
    view_name = view_name or "default",
    window = window,
    listeners = {},
    entry_text = et_cfg.on_start == true,
    log_mode = log_cfg_init.on_start == true,
  })

  local organ = require("organ")
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local debounce_ms = (view.refresh_debounce_ms or cfg.refresh_debounce_ms or 300)
  local timer
  local listener = function(payload)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if payload and payload.skipped then
      return
    end
    if timer then
      timer:stop()
      timer:close()
    end
    local t = vim.loop.new_timer()
    timer = t
    t:start(
      debounce_ms,
      0,
      vim.schedule_wrap(function()
        if t:is_closing() then
          return
        end
        t:stop()
        t:close()
        if timer == t then
          timer = nil
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
          M.refresh(bufnr)
        end
      end)
    )
  end

  local events = require("organ.events")
  events.on("indexed", listener)

  require("organ.errors").autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      events.off("indexed", listener)
      if timer then
        pcall(function()
          timer:stop()
          timer:close()
        end)
      end
      -- Drop the sticky registry entry pointing here so a subsequent
      -- :Org agenda creates a fresh buffer instead of trying to reuse
      -- this (now-wiped) bufnr.
      for k, v in pairs(M._sticky) do
        if v == bufnr then
          M._sticky[k] = nil
        end
      end
    end,
  })

  -- WinResized: rerender so the tag-overflow check (virt_text vs
  -- single-cell marker) re-evaluates against the new content width.
  -- Without this, a window narrowed AFTER initial render still has
  -- the original full-tag virt_text emitted at the right edge — and
  -- with line text now wider than (window - tag_width), the virt_text
  -- visually overlaps the END of the title.  Refresh is debounced
  -- through the same timer the indexed-listener uses so back-to-back
  -- resizes don't thrash.
  local resize_group =
    vim.api.nvim_create_augroup("organ_agenda_resize_" .. bufnr, { clear = true })
  local resize_timer
  require("organ.errors").autocmd("WinResized", {
    group = resize_group,
    callback = function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      -- Only refresh when this buffer is actually visible somewhere.
      local visible = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then
          visible = true
          break
        end
      end
      if not visible then
        return
      end
      if resize_timer then
        resize_timer:stop()
        resize_timer:close()
      end
      local t = vim.loop.new_timer()
      resize_timer = t
      t:start(
        50,
        0,
        vim.schedule_wrap(function()
          if t:is_closing() then
            return
          end
          t:stop()
          t:close()
          if resize_timer == t then
            resize_timer = nil
          end
          if vim.api.nvim_buf_is_valid(bufnr) then
            M.refresh(bufnr)
          end
        end)
      )
    end,
  })

  keymaps.install(bufnr, M)

  -- Window-open strategy (Emacs `org-agenda-window-setup`).  Default
  -- "reuse" replaces the current window's buffer (preserves layout).
  -- Other shapes:
  --   "only"          → close other windows, agenda fills the tab
  --   "split-below"   → horizontal split beneath the current window
  --   "vsplit-right"  → vertical split to the right
  --   "tab"           → new tab page
  -- When `restore_windows_after_quit` is on, the previous layout is
  -- snapshot-and-restored on `q` close.
  local cfg_open = cfg.window_setup or "reuse"
  local cfg_restore = cfg.restore_windows_after_quit == true
  local restore_view
  if cfg_restore then
    restore_view = vim.fn.winrestcmd()
  end

  if cfg_open == "only" then
    pcall(vim.cmd, "only")
    vim.api.nvim_set_current_buf(bufnr)
  elseif cfg_open == "split-below" then
    vim.cmd("belowright new")
    vim.api.nvim_set_current_buf(bufnr)
  elseif cfg_open == "vsplit-right" then
    vim.cmd("rightbelow vnew")
    vim.api.nvim_set_current_buf(bufnr)
  elseif cfg_open == "tab" then
    vim.cmd("tabnew")
    vim.api.nvim_set_current_buf(bufnr)
  else -- "reuse" / "current" / unknown
    vim.api.nvim_set_current_buf(bufnr)
  end

  if cfg_restore and restore_view then
    -- Defer the restore command to `q` close so it runs in the
    -- right window context.  Stash on the buffer var so it survives
    -- across refresh cycles.
    vim.b[bufnr].organ_agenda_restore_cmd = restore_view
  end

  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_set_option_value("foldmethod", "expr", { win = winid })
  vim.api.nvim_set_option_value(
    "foldexpr",
    "v:lua.require'organ.agenda'.foldexpr(v:lnum)",
    { win = winid }
  )
  vim.api.nvim_set_option_value("foldlevel", 99, { win = winid })
  -- Emacs's agenda buffer has `truncate-lines` on; mirror that so long
  -- title rows don't wrap and so `virt_text_pos = "right_align"` tags
  -- always anchor cleanly at the window's right edge.
  vim.api.nvim_set_option_value("wrap", false, { win = winid })

  -- Window-local winbar + statusline. Buffer-local only — never touches
  -- the user's global `vim.o.winbar` / `vim.o.statusline`. Each is opt-out
  -- (`agenda.winbar = false` / `agenda.statusline = false`) and accepts a
  -- string OR function override. See `:h organ-statusline` for the
  -- composable pieces if the user wants to compose their own.
  require("organ.statusline").apply(bufnr, {
    winbar = cfg.winbar,
    winbar_default = "agenda_winbar",
    statusline = cfg.statusline,
    statusline_default = "agenda_statusline",
  })

  M.refresh(bufnr)
  return bufnr
end

-- Exposed for tests: invokes the same filter pipeline (file-based
-- includes, todo-list ignores, COMMENT-tree skip, skip-if-done,
-- overdue-rollup, tag-match predicate, …) the agenda buffer uses.
M._run_query = collect.run_query
M._register_highlights = highlights.register

-- High-level entry points (the cmd.lua shims forward to these).

M.day = views.day
M.week = views.week
M.todos = views.todos
M.tags = views.tags
M.search = views.search
M.stuck = views.stuck
M.named_view = views.named_view
M.dispatch = views.dispatch
M._show_popup_menu = views._show_popup_menu
M.commands = views.commands

return M
