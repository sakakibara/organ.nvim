-- Agenda buffer for organ.nvim.
--
-- Orchestrator: buffer machinery (open/refresh), view state, keymaps +
-- autocmds, views, dispatch, commands. The pipeline stages live in
-- focused submodules:
--   * agenda/collect.lua    per-block record collection + annotation
--   * agenda/render.lua     records -> { lines, extmarks, line_index, block_starts }
--   * agenda/format.lua     record -> display line (prefix mini-format-language)
--   * agenda/dates.lua      date/time helpers + deterministic clock override
--   * agenda/highlights.lua, agenda/groups.lua

local M = {}

local obuf = require("organ.buf")
local highlights = require("organ.agenda.highlights")
local dates = require("organ.agenda.dates")
local format = require("organ.agenda.format")
local render = require("organ.agenda.render")
local collect = require("organ.agenda.collect")

-- Public pure helpers.

local FLAT_FIELDS = {
  "from",
  "to",
  "types",
  "todo",
  "tags",
  "priority",
  "title_match",
  "tag_match",
  "group_by",
  "include_overdue",
  "order_within_group",
  "line_format",
  "kind",
  "label",
  "sorting_strategy",
  "groups",
  -- Date-window controls (resolve to from/to in M.resolve_span).
  "span",
  "start_day",
  "week_starts_on",
}

-- Maps `week_starts_on` config strings to ISO weekday numbers.  The
-- sentinel "today" returns nil, which the caller interprets as "no
-- weekday anchor; the window starts on the anchor date as-is".
local WEEKDAY_NAME_TO_ISO = {
  monday = 1,
  tuesday = 2,
  wednesday = 3,
  thursday = 4,
  friday = 5,
  saturday = 6,
  sunday = 7,
}

local function resolve_week_anchor(value)
  if value == "today" then
    return nil
  end
  if type(value) == "string" then
    local n = WEEKDAY_NAME_TO_ISO[value:lower()]
    if n then
      return n
    end
  end
  return 1 -- default Monday for any unrecognized value
end

-- Resolve `span` + `start_day` + `week_starts_on` to absolute
-- `from` / `to` ISO dates.  Mirrors Emacs's `org-agenda-span`,
-- `org-agenda-start-day`, and `org-agenda-start-on-weekday`.
--
-- Resolution is non-destructive: returns nil when the block already
-- has explicit `from`/`to` (the block's literal window wins) or when
-- no span is specified.  Otherwise returns (from_iso, to_iso) computed
-- from:
--   * start_day: anchor (default "today"; accepts ISO or "+Nd"/"-Nd")
--   * span:      one of "day" | "week" | "fortnight" | "month" |
--                "year" | <integer N> (N days)
--   * week_starts_on: weekly-view anchor.  "monday".."sunday" pin the
--                first day of the week; "today" disables the anchor.
--
-- Public so a test can exercise it without going through the full
-- agenda buffer creation chain.
function M.resolve_span(block, agenda_cfg)
  if block.from or block.to then
    return nil
  end
  agenda_cfg = agenda_cfg or {}
  local span = block.span or agenda_cfg.span
  if not span then
    return nil
  end

  local start_day = block.start_day or agenda_cfg.start_day or "today"
  local function resolve_anchor(s)
    if s == "today" then
      return dates.today_iso()
    end
    local sign, n = s:match("^([%+%-])(%d+)d$")
    if sign and n then
      local off = tonumber(n) * 86400 * (sign == "-" and -1 or 1)
      return os.date("%Y-%m-%d", dates.now_ts() + off)
    end
    if s:match("^%d%d%d%d%-%d%d%-%d%d") then
      return s:sub(1, 10)
    end
    return dates.today_iso()
  end
  local anchor = resolve_anchor(start_day)
  local anchor_ts = dates.iso_to_ts(anchor)
  if not anchor_ts then
    return nil
  end

  -- For "week" and "fortnight", shift the anchor backwards to the
  -- configured start-of-week day.  When the value is "today" (or any
  -- nil-resolving form), no shift happens -- the window starts on
  -- the anchor date itself.
  local function shift_to_weekstart(ts, dow_target)
    if dow_target == nil then
      return ts
    end
    local w = tonumber(os.date("%w", ts)) -- 0..6
    local iso = (w == 0) and 7 or w
    local back = (iso - dow_target) % 7
    return ts - back * 86400
  end

  local raw = block.week_starts_on
  if raw == nil then
    raw = agenda_cfg.week_starts_on
  end
  local sow = resolve_week_anchor(raw)

  local from_ts, to_ts
  if span == "day" or span == 1 then
    from_ts, to_ts = anchor_ts, anchor_ts
  elseif span == "week" then
    from_ts = shift_to_weekstart(anchor_ts, sow)
    to_ts = from_ts + 6 * 86400
  elseif span == "fortnight" then
    from_ts = shift_to_weekstart(anchor_ts, sow)
    to_ts = from_ts + 13 * 86400
  elseif span == "month" then
    local dt = os.date("*t", anchor_ts)
    from_ts = os.time({ year = dt.year, month = dt.month, day = 1, hour = 12 })
    -- Last day = day before the first of next month.
    local nm_y, nm_m = dt.year, dt.month + 1
    if nm_m > 12 then
      nm_y, nm_m = nm_y + 1, 1
    end
    to_ts = os.time({ year = nm_y, month = nm_m, day = 1, hour = 12 }) - 86400
  elseif span == "year" then
    local dt = os.date("*t", anchor_ts)
    from_ts = os.time({ year = dt.year, month = 1, day = 1, hour = 12 })
    to_ts = os.time({ year = dt.year, month = 12, day = 31, hour = 12 })
  elseif type(span) == "number" and span > 0 then
    from_ts = anchor_ts
    to_ts = anchor_ts + (span - 1) * 86400
  else
    return nil -- unknown span shape, fall through
  end
  return os.date("%Y-%m-%d", from_ts), os.date("%Y-%m-%d", to_ts)
end

function M.normalize_view(v, view_name)
  view_name = view_name or "default_view"
  if type(v) ~= "table" then
    return nil, ("agenda view '%s': expected a table, got %s"):format(view_name, type(v))
  end
  if v.blocks ~= nil then
    for _, k in ipairs(FLAT_FIELDS) do
      if v[k] ~= nil then
        return nil,
          ("agenda view '%s': cannot mix top-level filter fields with 'blocks'"):format(view_name)
      end
    end
    if type(v.blocks) ~= "table" then
      return nil,
        ("agenda view '%s': 'blocks' must be a table, got %s"):format(view_name, type(v.blocks))
    end
    if #v.blocks == 0 then
      return nil, ("agenda view '%s': blocks list is empty"):format(view_name)
    end
    for i, b in ipairs(v.blocks) do
      if type(b.label) ~= "string" or b.label == "" then
        return nil, ("agenda view '%s': block at index %d missing 'label'"):format(view_name, i)
      end
    end
    local blocks = {}
    for i, b in ipairs(v.blocks) do
      local copy = {}
      for k, val in pairs(b) do
        copy[k] = val
      end
      blocks[i] = copy
    end
    -- Resolve span → from/to for each block that asked for it.
    local agenda_cfg_n = (require("organ.buf_config").read(nil, "agenda") or {})
    for _, b in ipairs(blocks) do
      local rfrom, rto = M.resolve_span(b, agenda_cfg_n)
      if rfrom and rto then
        b.from, b.to = rfrom, rto
      end
    end
    return { blocks = blocks, refresh_debounce_ms = v.refresh_debounce_ms }
  end
  local block = {}
  for _, k in ipairs(FLAT_FIELDS) do
    block[k] = v[k]
  end
  -- Same span-resolve for the flat (single-block) view shape.
  local agenda_cfg_n = (require("organ.buf_config").read(nil, "agenda") or {})
  local rfrom, rto = M.resolve_span(block, agenda_cfg_n)
  if rfrom and rto then
    block.from, block.to = rfrom, rto
  end
  return { blocks = { block }, refresh_debounce_ms = v.refresh_debounce_ms }
end

-- Validate a path the user typed at the M-CR add-entry prompt.
-- Returns (true, nil) when safe, or (false, reason) otherwise.
--
-- Refuses two failure modes:
--   1. extension is not .org / .org_archive
--      (writefile OVERWRITES; a fat-finger accept of a wrong default
--       shouldn't clobber /etc/passwd or a binary file)
--   2. canonical path doesn't start with config.org_dir
--      (constrains the write to the user's workspace)
--
-- Public so a test can exercise the rules without going through the
-- M-CR keymap chain.
function M.add_entry_path_ok(file)
  if type(file) ~= "string" or file == "" then
    return false, "empty path"
  end
  if not file:match("%.org$") and not file:match("%.org_archive$") then
    return false, "refusing to write non-.org file: " .. file
  end
  local org_dir = require("organ.buf_config").read(nil, "org_dir")
  if org_dir and org_dir ~= "" then
    local canon = require("organ.path").canonical(file) or file
    local canon_dir = require("organ.path").canonical(org_dir) or org_dir
    if canon:sub(1, #canon_dir) ~= canon_dir then
      return false, "refusing to write outside org_dir: " .. file
    end
  end
  return true
end

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

-- vim.b serialises sparse-int-keyed Lua tables by padding gaps with vim.NIL.
-- Re-key block_starts and line_index as strings before storing, then decode
-- back to integers on read. Other state fields are dense or scalar — safe.
local function encode_state(state)
  local enc = {}
  for k, v in pairs(state) do
    enc[k] = v
  end
  if state.block_starts then
    local s = {}
    for k, v in pairs(state.block_starts) do
      s[tostring(k)] = v
    end
    enc.block_starts = s
  end
  if state.line_index then
    local s = {}
    for k, v in pairs(state.line_index) do
      s[tostring(k)] = v
    end
    enc.line_index = s
  end
  return enc
end

local function decode_state(raw)
  if not raw then
    return {}
  end
  local dec = {}
  for k, v in pairs(raw) do
    dec[k] = v
  end
  if raw.block_starts then
    local s = {}
    for k, v in pairs(raw.block_starts) do
      s[tonumber(k) or k] = v
    end
    dec.block_starts = s
  end
  if raw.line_index then
    local s = {}
    for k, v in pairs(raw.line_index) do
      s[tonumber(k) or k] = v
    end
    dec.line_index = s
  end
  return dec
end

local function buf_state(bufnr)
  return decode_state(vim.b[bufnr].organ_agenda)
end

-- Public accessor so tests and keymaps can read decoded state (with integer
-- block_starts keys) without accessing vim.b directly.
function M.buf_state(bufnr)
  return buf_state(bufnr)
end

local function set_state(bufnr, state)
  vim.b[bufnr].organ_agenda = encode_state(state)
end

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
  local hstate = buf_state(bufnr) or {}
  hstate.delete_history = hstate.delete_history or {}
  hstate.delete_history[#hstate.delete_history + 1] = snapshot
  hstate.redo_history = {}
  set_state(bufnr, hstate)
  return snapshot
end

-- Pop the top of bufnr's delete_history and re-insert each subtree at
-- its captured (file, lnum). Pushes onto redo_history. Returns the
-- snapshot, or nil when the stack is empty.
function M.undo_last_delete(bufnr)
  local state = buf_state(bufnr) or {}
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
  set_state(bufnr, state)
  return snap
end

-- Pop the top of bufnr's redo_history and re-cut. Pushes back onto
-- delete_history. Returns the snapshot or nil.
function M.redo_last_delete(bufnr)
  local state = buf_state(bufnr) or {}
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
  set_state(bufnr, state)
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
  local state = buf_state(bufnr)
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
  local rstate = buf_state(bufnr)
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
    local agenda_state = decode_state(vim.b[bufnr].organ_agenda) or {}
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
  set_state(bufnr, state)

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

local function install_keymaps(bufnr)
  local organ = require("organ")
  local agenda_cfg = require("organ.buf_config").read(nil, "agenda") or {}
  -- Rule 2: keymaps = false disables all agenda bindings.
  if agenda_cfg.keymaps == false then
    return
  end
  local cfg = agenda_cfg.keymaps or {}

  local function map(default_lhs, rhs, desc)
    local lhs = cfg[desc] -- user may override via organ.config.agenda.keymaps[desc]
    if lhs == false then
      return
    end
    if lhs == nil then
      lhs = default_lhs
    end
    vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      desc = desc,
      callback = rhs,
    })
  end

  local function current_row()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    return (state.line_index or {})[lnum]
  end

  -- Helper: load the source buffer + return the 1-based source line for a
  -- row. Returns nil + warns if the row has no editable source (synthetic
  -- diary_sexp rows, empty-state placeholders, etc. lack file_path /
  -- line_start). Without this guard, every t/T/s/D/I/R/<CR>/gs/gv keymap
  -- would crash with `attempt to perform arithmetic on field 'line_start'
  -- (a nil value)` on synthetic rows.
  local function source_for(r)
    if not r.file_path or not r.line_start then
      require("organ.notify").warn(
        "agenda: this row has no editable source (synthetic / placeholder)"
      )
      return nil, nil
    end
    local target = vim.fn.bufadd(r.file_path)
    vim.fn.bufload(target)
    return target, r.line_start + 1
  end

  map("<CR>", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "jump")

  -- Preview the source headline + body in a floating window without
  -- leaving the agenda buffer. Press `q` or `<Esc>` (anything that
  -- closes the float) to dismiss. K is unbound in vim's normal-mode
  -- defaults for nofile buffers; override is non-conflicting.
  map("K", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path or not r.line_start then
      return
    end
    local target = vim.fn.bufadd(r.file_path)
    vim.fn.bufload(target)
    -- Slice from headline to subtree end.
    local structure = require("organ.structure")
    local hl = structure._find_containing_headline(target, (r.line_start or 0) + 1)
    if not hl then
      return
    end
    local subtree_end = structure._subtree_end(target, hl)
    local lines = vim.api.nvim_buf_get_lines(target, hl.line - 1, subtree_end, false)
    -- Width: longest line + small padding, capped to ~edge of window.
    local max_w = 0
    for _, l in ipairs(lines) do
      max_w = math.max(max_w, vim.fn.strdisplaywidth(l))
    end
    local width = math.min(math.max(max_w + 4, 40), math.floor(vim.o.columns * 0.8))
    local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
    -- vim.lsp.util.open_floating_preview handles q / Esc dismissal +
    -- closes on cursor move. Set filetype=org so syntax highlights.
    local _, _ = vim.lsp.util.open_floating_preview(lines, "org", {
      width = width,
      height = height,
      border = "rounded",
    })
  end, "preview")

  -- Open in horizontal/vertical split. `gs` / `gv` — single-finger
  -- two-key sequences in the vim "go" family (`g` prefix is the
  -- canonical "go to" namespace). Both have no-op vim defaults in a
  -- nomodifiable buffer (vim's `gs` sleeps, `gv` re-enters last
  -- visual selection — neither does anything useful here).
  --
  -- We deliberately don't bind bare `o` or `v`: those shadow vim's
  -- normal-mode `o` (open new line) and `v` (visual-character mode)
  -- which users have hard-wired muscle memory for.
  map("gs", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("split " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "open_split")

  map("gv", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("vsplit " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "open_vsplit")

  map("r", function()
    M.refresh(bufnr)
  end, "refresh")

  -- `E` toggles entry-text mode (Emacs `org-agenda-entry-text-mode`):
  -- inject up to `agenda.entry_text.max_lines` body lines from each
  -- item's source headline as indented preview rows under the row.
  map("E", function()
    local state = buf_state(bufnr)
    state.entry_text = not state.entry_text
    set_state(bufnr, state)
    M.refresh(bufnr)
  end, "toggle_entry_text")

  -- `l` toggles log mode (Emacs `org-agenda-log-mode`): inject CLOSED
  -- entries (and clock / state events when those land in the indexer)
  -- as additional rows on the day each event happened.  Set
  -- `agenda.log_mode.on_start = true` to default it on.
  map("l", function()
    local state = buf_state(bufnr)
    state.log_mode = not state.log_mode
    set_state(bufnr, state)
    M.refresh(bufnr)
  end, "toggle_log_mode")

  -- Undo last destructive bulk op (delete, currently). Pops the
  -- per-buffer history stack and re-inserts each captured subtree at
  -- its original file:line position. Vim's native `u` is a no-op in
  -- this nofile non-modifiable buffer, so overriding it gives users
  -- the seamless "vim-native undo feel" they expect — no
  -- :Org paste_subtree dance.
  map("u", function()
    local snap = M.undo_last_delete(bufnr)
    if not snap then
      require("organ.notify").info("agenda: nothing to undo")
      return
    end
    M.refresh(bufnr)
    require("organ.notify").info(("agenda: restored %d subtree(s)"):format(#snap))
  end, "undo_delete")

  -- Redo the last undone delete. Vim convention: <C-r>.
  map("<C-r>", function()
    local snap = M.redo_last_delete(bufnr)
    if not snap then
      require("organ.notify").info("agenda: nothing to redo")
      return
    end
    M.refresh(bufnr)
    require("organ.notify").info(("agenda: re-deleted %d subtree(s)"):format(#snap))
  end, "redo_delete")

  map("q", function()
    -- Snapshot any layout-restore command set up by M.open and run it
    -- AFTER the buffer is gone so the previous window arrangement
    -- comes back (Emacs `org-agenda-restore-windows-after-quit`).
    local restore = vim.b[bufnr].organ_agenda_restore_cmd
    vim.api.nvim_buf_delete(bufnr, { force = true })
    if restore and restore ~= "" then
      pcall(vim.cmd, restore)
    end
  end, "close")

  map("j", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    local total = vim.api.nvim_buf_line_count(bufnr)
    for i = lnum + 1, total do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "next_item")

  map("k", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    for i = lnum - 1, 1, -1 do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "prev_item")

  map("/", function()
    local input = vim.fn.input("filter title: ")
    local state = buf_state(bufnr)
    local view = state.view or { blocks = {} }
    for _, block in ipairs(view.blocks) do
      block.title_match = input ~= "" and input or nil
    end
    state.view = view
    set_state(bufnr, state)
    M.refresh(bufnr)
  end, "filter")

  map("<Tab>", function()
    vim.cmd("normal! za")
  end, "fold")

  map("]]", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    local starts = state.block_starts or {}
    local target
    for k in pairs(starts) do
      if k > lnum and (target == nil or k < target) then
        target = k
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
  end, "next_block")

  map("[[", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = buf_state(bufnr)
    local starts = state.block_starts or {}
    local target
    for k in pairs(starts) do
      if k < lnum and (target == nil or k > target) then
        target = k
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
  end, "prev_block")

  map("g?", function()
    local help = {
      "organ.agenda keymaps",
      "  Navigation",
      "    <CR>  jump to source         gs / gv  split / vsplit",
      "    j / k  next/prev item        ]] / [[  next/prev block",
      "    <Tab>  toggle block fold     /        title filter",
      "  Period",
      "    f / b  next/prev             .        today",
      "    gd / gw  day/week view       gj       jump to date",
      "  Per-row edit",
      "    t  cycle TODO                T        TODO menu",
      "    s  schedule                  D        deadline",
      "    +  raise priority            -        lower priority",
      "    =  clear priority            gT       set tags",
      "    R  refile                    I / O    clock in/out",
      "    e  effort filter",
      "  Bulk",
      "    <Space>  mark + advance      gM       mark all toggle",
      "    gB       apply action menu",
      "    u        undo last delete    <C-r>    redo last undone",
      "  Misc",
      "    A   archive row                gA  show/hide archived",
      "    gC  open clock report          gR  toggle in-agenda clocktable",
      "    <M-CR>  new entry            r   refresh",
      "    q   close                    g?  this help",
    }
    vim.api.nvim_echo({ { table.concat(help, "\n"), "None" } }, true, {})
  end, "help")

  map("t", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local err = require("organ.todo").cycle(target, lnum)
    if err then
      require("organ.notify").error(err)
    end
  end, "todo_cycle")

  map("T", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    -- Use the SOURCE FILE's sequence (file-level `#+TODO:` directive
    -- wins over global config), matching Emacs's per-file behavior.
    local choices = { "(none)" }
    for _, k in ipairs(require("organ.todo").all_keywords()) do
      choices[#choices + 1] = k
    end
    -- If the row's source buffer is loaded, prefer its file-level
    -- directives over global; otherwise fall back to global keywords.
    if vim.api.nvim_buf_is_valid(target) then
      local seqs = require("organ.todo").effective_sequences(target)
      local seen, file_choices = {}, { "(none)" }
      for _, seq in ipairs(seqs) do
        for _, k in ipairs(seq) do
          if k ~= "|" and not seen[k] then
            seen[k] = true
            file_choices[#file_choices + 1] = k
          end
        end
      end
      if #file_choices > 1 then
        choices = file_choices
      end
    end
    vim.ui.select(choices, { prompt = "TODO state: " }, function(choice)
      if not choice then
        return
      end
      local state = choice == "(none)" and nil or choice
      local err = require("organ.todo").set(target, lnum, state)
      if err then
        require("organ.notify").error(err)
      end
    end)
  end, "todo_set")

  -- Priority: ^ raise, _ lower, $ clear (Emacs convention).
  -- Priority shortcuts — `+` raise, `-` lower, `=` clear. Mnemonic:
  -- + = more, - = less, = = none. Avoids vim's `^`/`$` (line start/end
  -- navigation, useful even in fixed-format buffers).
  map("+", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").raise_priority(target, lnum)
    M.refresh(bufnr)
  end, "priority_raise")

  map("-", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").lower_priority(target, lnum)
    M.refresh(bufnr)
  end, "priority_lower")

  map("=", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").set_priority(target, lnum, nil)
    M.refresh(bufnr)
  end, "priority_clear")

  -- Jump to a specific date (Emacs `j` in org-agenda; we use `gj` since
  -- `j` is already bound to next-item-line).
  map("gj", function()
    vim.ui.input({ prompt = "Jump to date (YYYY-MM-DD or 'today', '+1w'…): " }, function(input)
      if not input or input == "" then
        return
      end
      local query = require("organ.query")
      local parsed = nil
      if query.parse_date then
        local ok, p = pcall(query.parse_date, input)
        if ok and p then
          parsed = p
        end
      end
      -- Fall back to literal pass-through when parse_date isn't available
      -- or doesn't recognise the input — _set_window will validate.
      parsed = parsed or input
      M._set_window(bufnr, parsed, parsed)
      M.refresh(bufnr)
    end)
  end, "jump_to_date")

  -- Bulk selection + action menu (Emacs `m`/`u`/`*`/`B B`).
  -- Marks are stored on buf_state.bulk_marked as { [src_id] = true }
  -- and rendered as a sign in the agenda buffer's gutter. Action menu
  -- (`B`) iterates marked rows and applies one of: state change,
  -- schedule, deadline, refile, archive, delete-subtree.
  --
  -- Mark id: row.id when present; else file_path .. ":" .. line_start.
  local function row_mark_id(r)
    if not r then
      return nil
    end
    if r.id then
      return r.id
    end
    if r.file_path and r.line_start then
      return r.file_path .. ":" .. r.line_start
    end
    return nil
  end

  local SIGN_GROUP = "organ_agenda_bulk_" .. bufnr
  local SIGN_NAME = "OrganAgendaBulk"
  pcall(vim.fn.sign_define, SIGN_NAME, { text = "▎", texthl = "@organ.agenda.priority_A" })

  local function redraw_bulk_signs()
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
    local state = buf_state(bufnr)
    local marked = state.bulk_marked or {}
    for lnum, r in pairs(state.line_index or {}) do
      local id = row_mark_id(r)
      if id and marked[id] then
        pcall(vim.fn.sign_place, 0, SIGN_GROUP, SIGN_NAME, bufnr, { lnum = lnum, priority = 10 })
      end
    end
  end

  local function set_marked(id, value)
    local state = buf_state(bufnr)
    state.bulk_marked = state.bulk_marked or {}
    state.bulk_marked[id] = value or nil
    set_state(bufnr, state)
    redraw_bulk_signs()
  end

  -- <Space> toggles bulk mark on the cursor row + advances to next
  -- item. Space is unmapped in vim-default normal mode (it's <Right>
  -- as motion), so this is the cleanest single-key for bulk select
  -- without colliding with `*` (search-word) or `m` (set register).
  map("<Space>", function()
    local r = current_row()
    local id = row_mark_id(r)
    if id then
      local state = buf_state(bufnr)
      state.bulk_marked = state.bulk_marked or {}
      local on = state.bulk_marked[id]
      state.bulk_marked[id] = (not on) and true or nil
      set_state(bufnr, state)
      redraw_bulk_signs()
    end
    -- Advance to the next item row.
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local total = vim.api.nvim_buf_line_count(bufnr)
    local state = buf_state(bufnr)
    for i = lnum + 1, total do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "bulk_mark_toggle")

  -- gM toggles bulk mark for ALL visible rows. (gM is unbound in vim
  -- default; capital M alone moves to middle of window — useful — and
  -- `*` is search-word — also useful — so we use the g prefix.)
  map("gM", function()
    local state = buf_state(bufnr)
    state.bulk_marked = state.bulk_marked or {}
    local any = next(state.bulk_marked) ~= nil
    if any then
      state.bulk_marked = {}
    else
      for _, r in pairs(state.line_index or {}) do
        local id = row_mark_id(r)
        if id then
          state.bulk_marked[id] = true
        end
      end
    end
    set_state(bufnr, state)
    redraw_bulk_signs()
  end, "bulk_mark_all")

  -- gB applies the action menu to every marked row. (vim's `B` is
  -- back-WORD which we keep available.) Iterates marked rows, prompts
  -- for action, applies.
  -- Resolves each marked id back to its source via the buffer's
  -- line_index (we look up live so cursor moves don't matter).
  map("gB", function()
    local state = buf_state(bufnr)
    local marked = state.bulk_marked or {}
    local marked_rows = {}
    for _, r in pairs(state.line_index or {}) do
      local id = row_mark_id(r)
      if id and marked[id] then
        marked_rows[#marked_rows + 1] = r
      end
    end
    if #marked_rows == 0 then
      require("organ.notify").warn("agenda: no rows marked (press <Space> to mark)")
      return
    end
    local actions = {
      { "Set TODO state", "todo" },
      { "Schedule", "schedule" },
      { "Set deadline", "deadline" },
      { "Refile", "refile" },
      { "Archive subtree", "archive" },
      { "Delete subtree", "delete" },
    }
    local labels = {}
    for _, a in ipairs(actions) do
      labels[#labels + 1] = a[1]
    end
    vim.ui.select(
      labels,
      { prompt = ("Bulk (%d rows):"):format(#marked_rows) },
      function(choice, idx)
        if not choice then
          return
        end
        if not idx then
          for i, l in ipairs(labels) do
            if l == choice then
              idx = i
              break
            end
          end
        end
        if not idx then
          return
        end
        local kind = actions[idx][2]
        local apply
        if kind == "todo" then
          local cfg = require("organ.buf_config").read(nil, "todo") or {}
          local choices = { "(none)" }
          for _, k in ipairs(cfg.sequence or {}) do
            if k ~= "|" then
              choices[#choices + 1] = k
            end
          end
          vim.ui.select(choices, { prompt = "TODO state for all marked: " }, function(state_choice)
            if not state_choice then
              return
            end
            local new_state = state_choice == "(none)" and nil or state_choice
            for _, r in ipairs(marked_rows) do
              local target, lnum = source_for(r)
              if target then
                pcall(require("organ.todo").set, target, lnum, new_state)
              end
            end
            state.bulk_marked = {}
            set_state(bufnr, state)
            redraw_bulk_signs()
            M.refresh(bufnr)
          end)
          return
        elseif kind == "schedule" then
          apply = function(target, lnum)
            require("organ.schedule").set_schedule(target, lnum)
          end
        elseif kind == "deadline" then
          apply = function(target, lnum)
            require("organ.schedule").set_deadline(target, lnum)
          end
        elseif kind == "refile" then
          -- Bulk-refile is fiddly (one target, multiple sources) — fall
          -- back to triggering the per-row refile picker for each marked
          -- row. The user picks a destination once per row.
          apply = function(target, lnum)
            local saved = vim.api.nvim_get_current_buf()
            vim.api.nvim_set_current_buf(target)
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            pcall(require("organ.refile").refile)
            pcall(vim.api.nvim_set_current_buf, saved)
          end
        elseif kind == "archive" then
          apply = function(target, lnum)
            require("organ.archive").archive_subtree(target, lnum)
          end
        elseif kind == "delete" then
          local confirm = vim.fn.confirm(
            ("Delete %d subtree(s)? Press `u` in this buffer to undo."):format(#marked_rows),
            "&Yes\n&No",
            2
          )
          if confirm ~= 1 then
            return
          end
          -- Resolve marked_rows to (target_buf, lnum) pairs and hand
          -- to M.bulk_delete_apply. The public function snapshots,
          -- cuts, and pushes to delete_history.
          local resolved = {}
          for _, r in ipairs(marked_rows) do
            local target, lnum = source_for(r)
            if target then
              resolved[#resolved + 1] = { _source_bufnr = target, _source_lnum = lnum }
            end
          end
          local snapshot = M.bulk_delete_apply(bufnr, resolved)
          state.bulk_marked = {}
          set_state(bufnr, state)
          redraw_bulk_signs()
          M.refresh(bufnr)
          require("organ.notify").info(("Deleted %d subtree(s). `u` to undo."):format(#snapshot))
          return
        end
        if apply then
          for _, r in ipairs(marked_rows) do
            local target, lnum = source_for(r)
            if target then
              pcall(apply, target, lnum)
            end
          end
          state.bulk_marked = {}
          set_state(bufnr, state)
          redraw_bulk_signs()
          M.refresh(bufnr)
        end
      end
    )
  end, "bulk_action")

  -- Set tags on row at cursor. Bound to `gT` (override vim's "previous
  -- tab" — agenda buffers usually live in a single tab, and the
  -- alternative `:` would shadow vim's command-mode trigger which
  -- users press constantly). For users who DO want :tabprev, vim's
  -- `:tabprevious` command is always available.
  map("gT", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local cur = require("organ.tag_writer").read(target, lnum) or {}
    vim.ui.input(
      { prompt = "Tags (space- or colon-separated): ", default = table.concat(cur, " ") },
      function(input)
        if input == nil then
          return
        end
        local tags = {}
        for tok in input:gmatch("[^%s:]+") do
          tags[#tags + 1] = tok
        end
        require("organ.tag_writer").write(target, lnum, tags)
        M.refresh(bufnr)
      end
    )
  end, "set_tags")

  -- Toggle whether archived headlines are SHOWN in the agenda. Bound
  -- to `gA` so the user's vim `;` (repeat f/F/t/T) stays usable.
  -- Distinct from `A` below, which archives the row at cursor.
  map("gA", function()
    local state = buf_state(bufnr)
    state.show_archived = not state.show_archived
    set_state(bufnr, state)
    require("organ.notify").info(
      "agenda: archived rows " .. (state.show_archived and "shown" or "hidden")
    )
    M.refresh(bufnr)
  end, "toggle_archived_visibility")

  -- Archive the source headline of the row at cursor (Emacs `$` in
  -- agenda → `org-agenda-archive`). We use uppercase `A` because our
  -- `$` is bound to clear-priority and lowercase `a` is unbound and
  -- frequently typed by mistake.
  map("A", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local err = require("organ.archive").archive_subtree(target, lnum)
    if err then
      require("organ.notify").error(tostring(err))
      return
    end
    require("organ.notify").info("archived")
    M.refresh(bufnr)
  end, "archive_row")

  -- Open clock report from agenda. `c` is unbound in vim default
  -- normal mode (the `c` family — `cw`, `cc` — are operator-pending,
  -- which still works because `c` alone waits for a motion. We
  -- override only the wait-for-motion case in this nofile buffer
  -- where text-changing motions are no-ops anyway.)
  map("gC", function()
    pcall(require("organ.clock").report)
  end, "clock_report")

  -- gR: toggle in-agenda clock-report mode (Emacs `R` in agenda buffer
  -- but R is taken by refile; use gR to mirror the "g-prefix for go-do"
  -- pattern). When on, the agenda renderer appends a clocktable showing
  -- clocked time for headlines visible in the current window. Toggle
  -- again to remove.
  map("gR", function()
    local state = buf_state(bufnr)
    state.clock_report_mode = not state.clock_report_mode
    set_state(bufnr, state)
    require("organ.notify").info(
      "agenda: clock-report mode " .. (state.clock_report_mode and "ON" or "OFF")
    )
    M.refresh(bufnr)
  end, "toggle_clock_report")

  -- M-CR: add a new TODO heading. Prompts for title, then for target file
  -- (defaults to the current row's file or org_dir's first file).
  map("<M-CR>", function()
    local default_path
    local r = current_row()
    if r and r.file_path then
      default_path = r.file_path
    end
    if not default_path then
      local org_dir = require("organ.buf_config").read(nil, "org_dir")
      if org_dir and org_dir ~= "" then
        local fd = vim.uv.fs_scandir(org_dir)
        if fd then
          while true do
            local n, t = vim.uv.fs_scandir_next(fd)
            if not n then
              break
            end
            if t == "file" and n:match("%.org$") then
              default_path = org_dir .. "/" .. n
              break
            end
          end
        end
      end
    end
    vim.ui.input({ prompt = "New TODO: " }, function(title)
      if not title or title == "" then
        return
      end
      vim.ui.input({ prompt = "File: ", default = default_path or "" }, function(file)
        if not file or file == "" then
          return
        end
        local ok_path, why = M.add_entry_path_ok(file)
        if not ok_path then
          require("organ.notify").error("agenda add-entry: " .. why)
          return
        end
        -- Append a new top-level TODO heading at end of file.
        local lines = vim.fn.readfile(file)
        if lines == nil then
          lines = {}
        end
        if #lines > 0 and lines[#lines] ~= "" then
          lines[#lines + 1] = ""
        end
        lines[#lines + 1] = "* TODO " .. title
        vim.fn.writefile(lines, file)
        require("organ.notify").info("appended to " .. file)
        -- Re-index + refresh agenda.
        require("organ.queue").enqueue_interactive(file)
        vim.defer_fn(function()
          M.refresh(bufnr)
        end, 200)
      end)
    end)
  end, "add_entry")

  -- Schedule / deadline: reuse the calendar picker on the source headline.
  map("s", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.schedule").set_schedule(target, lnum)
  end, "schedule")

  map("D", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.schedule").set_deadline(target, lnum)
  end, "deadline")

  -- Clocking from agenda.
  map("I", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.clock").start({ bufnr = target, line = lnum })
  end, "clock_in")

  map("O", function()
    require("organ.clock").stop({})
  end, "clock_out")

  -- Refile the source subtree: switch to source, position cursor, dispatch.
  map("R", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    vim.api.nvim_set_current_buf(target)
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    require("organ.refile").refile()
  end, "refile")

  -- Date navigation: shift the visible window forward/back by its own length;
  -- "." resets to today (range length preserved).
  map("f", function()
    M._shift_period(bufnr, 1)
    M.refresh(bufnr)
  end, "next_period")
  map("b", function()
    M._shift_period(bufnr, -1)
    M.refresh(bufnr)
  end, "prev_period")
  map(".", function()
    M._reset_today(bufnr)
    M.refresh(bufnr)
  end, "today")

  -- View-mode switches: 1-day / 7-day window starting today.
  -- View-window commands. Prefix `g` keeps them in the same family as
  -- `gs`/`gv` (open split/vsplit). The previous `vd`/`vw` bindings
  -- caused a 1-second timeoutlen wait on every bare `v` because vim had
  -- to disambiguate `v` (visual mode) vs `vd`/`vw` (these). With `gd`/`gw`
  -- the `v` key fires visual mode immediately.
  map("gd", function()
    M._set_window(bufnr, "today", "today")
    M.refresh(bufnr)
  end, "view_day")
  map("gw", function()
    M._set_window(bufnr, "today", "+6d")
    M.refresh(bufnr)
  end, "view_week")

  -- Effort filter. `e` prompts for a spec ("<30", "1:00..2:00", ">=60");
  -- empty input clears.
  map("e", function()
    vim.ui.input({ prompt = "Effort filter (e.g. <30, 1:00..2:00, >=1h): " }, function(input)
      if input == nil then
        return
      end
      local s = buf_state(bufnr)
      s.effort_filter = input
      set_state(bufnr, s)
      M.refresh(bufnr)
    end)
  end, "effort_filter")
end

-- Convert an ISO date "YYYY-MM-DD" to a unix timestamp (UTC midnight).
local function iso_to_time(iso)
  local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })
end

local function time_to_iso(t)
  local lt = os.date("*t", t)
  return string.format("%04d-%02d-%02d", lt.year, lt.month, lt.day)
end

local function shift_iso(iso, days)
  local t = iso_to_time(iso)
  if not t then
    return iso
  end
  return time_to_iso(t + days * 86400)
end

-- Shift every block's date window by n full periods (period = block span).
function M._shift_period(bufnr, n)
  local state = buf_state(bufnr)
  local view = state.view or { blocks = {} }
  local query = require("organ.query")
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      local from_iso = query.parse_date(block.from)
      local to_iso = query.parse_date(block.to)
      if from_iso and to_iso then
        local from_t = iso_to_time(from_iso)
        local to_t = iso_to_time(to_iso)
        local span = math.floor((to_t - from_t) / 86400) + 1
        local delta = n * span
        block.from = shift_iso(from_iso, delta)
        block.to = shift_iso(to_iso, delta)
      end
    end
  end
  state.view = view
  set_state(bufnr, state)
end

-- Reset every block's window to today, preserving its prior span.
function M._reset_today(bufnr)
  local state = buf_state(bufnr)
  local view = state.view or { blocks = {} }
  local query = require("organ.query")
  local today_iso = query.parse_date("today")
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      local from_iso = query.parse_date(block.from)
      local to_iso = query.parse_date(block.to)
      if from_iso and to_iso then
        local span = math.floor((iso_to_time(to_iso) - iso_to_time(from_iso)) / 86400)
        block.from = today_iso
        block.to = shift_iso(today_iso, span)
      end
    end
  end
  state.view = view
  set_state(bufnr, state)
end

-- Replace every block's window with the given (from, to) — relative or ISO.
function M._set_window(bufnr, from, to)
  local state = buf_state(bufnr)
  local view = state.view or { blocks = {} }
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      block.from = from
      block.to = to
    end
  end
  state.view = view
  set_state(bufnr, state)
end

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
      local state = decode_state(vim.b[existing].organ_agenda) or {}
      state.view = view
      state.view_name = view_name or "default"
      local first = view.blocks[1] or {}
      if first.from then
        state.window = { from = first.from, to = first.to }
      end
      vim.b[existing].organ_agenda = encode_state(state)
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
  set_state(bufnr, {
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

  vim.api.nvim_create_autocmd("BufWipeout", {
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
  vim.api.nvim_create_autocmd("WinResized", {
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

  install_keymaps(bufnr)

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

--- Open the day-view agenda (today only).
function M.day()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local view = vim.tbl_extend("force", {}, cfg.default_view or {}, {
    from = "today",
    to = "today",
  })
  M.open(view, "day")
end

--- Open the week-view agenda anchored to `agenda.week_starts_on`:
---   "monday".."sunday"   pin the first day of the week (default
---                        "monday", mirroring Emacs's default)
---   "today"              no fixed anchor; window is today..+6d
function M.week()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local sow = resolve_week_anchor(cfg.week_starts_on)
  local now_ts = os.time()
  local week_start_ts
  if sow == nil then
    week_start_ts = now_ts
  else
    local w = tonumber(os.date("%w", now_ts))
    local iso = (w == 0) and 7 or w
    local back = (iso - sow) % 7
    week_start_ts = now_ts - back * 86400
  end
  local week_end_ts = week_start_ts + 6 * 86400
  local view = vim.tbl_extend("force", {}, cfg.default_view or {}, {
    from = os.date("%Y-%m-%d", week_start_ts),
    to = os.date("%Y-%m-%d", week_end_ts),
  })
  M.open(view, "week")
end

--- Open the global TODO list (every active TODO across all org files).
function M.todos()
  M.open({
    blocks = {
      {
        label = "Global TODOs",
        kind = "todo",
        todo = { exclude = { "DONE", "CANCELLED", "CANCELED", "CLOSED" } },
      },
    },
  }, "todos")
end

--- Open a tag-match agenda view.  When `query` is nil/empty, prompts via
--- `vim.ui.input` (Emacs `M-x org-tags-view`).
function M.tags(query)
  local function go(q)
    if not q or q == "" then
      return
    end
    M.open({
      blocks = { { label = "Tag match: " .. q, kind = "tags", tag_match = q } },
    }, "tags:" .. q)
  end
  if query and query ~= "" then
    go(query)
    return
  end
  vim.ui.input({ prompt = "Tag query (e.g. work&urgent-@home): " }, go)
end

--- Open a title-search agenda view.  When `query` is nil/empty, prompts via
--- `vim.ui.input`.
function M.search(query)
  local function go(q)
    if not q or q == "" then
      return
    end
    M.open({
      blocks = { { label = "Search: " .. q, kind = "search", title_match = q } },
    }, "search:" .. q)
  end
  if query and query ~= "" then
    go(query)
    return
  end
  vim.ui.input({ prompt = "Search string: " }, go)
end

--- Open the stuck-projects view.
function M.stuck()
  M.open({ blocks = { { label = "Stuck projects", kind = "stuck" } } })
end

--- Open a user-defined named view from `config.agenda.views[name]`.  Surfaces
--- a notify error if the name is not registered.
function M.named_view(name)
  local views = (require("organ.buf_config").read(nil, "agenda") or {}).views or {}
  local view = views[name]
  if not view then
    require("organ.notify").error("organ: no agenda view named " .. tostring(name))
    return
  end
  M.open(view, name)
end

-- Build the dispatcher entry list (key, label, action).  Standard entries
-- + every named view + a "default" tail entry on `D` (or space if D is
-- already taken by a user view).
local function build_dispatch_entries()
  local entries = {
    { "a", "Week agenda", M.week },
    { "d", "Day agenda", M.day },
    { "t", "Global TODO list", M.todos },
    { "m", "Tag query…", M.tags },
    { "s", "Search by string…", M.search },
    { "#", "Stuck projects", M.stuck },
  }
  local views = (require("organ.buf_config").read(nil, "agenda") or {}).views or {}
  local used = {}
  for _, e in ipairs(entries) do
    used[e[1]] = true
  end
  local view_names = {}
  for k in pairs(views) do
    view_names[#view_names + 1] = k
  end
  table.sort(view_names)
  for _, k in ipairs(view_names) do
    local first = k:sub(1, 1)
    local key = (not used[first]) and first or nil
    if key then
      used[key] = true
    end
    entries[#entries + 1] = {
      key or " ",
      k,
      function()
        M.open(views[k], k)
      end,
    }
  end
  local def_key = used["D"] and " " or "D"
  used[def_key] = true
  entries[#entries + 1] = {
    def_key,
    "default",
    function()
      M.open((require("organ.buf_config").read(nil, "agenda") or {}).default_view, "default_view")
    end,
  }
  return entries
end
M._build_dispatch_entries = build_dispatch_entries

-- Show a single-keystroke menu in a centered floating window and
-- Thin wrapper around `organ.popup_menu.pick` -- the actual
-- single-keystroke popup primitive lives there so the TODO fast-
-- pick can use the same modal-blocking UI.
local function show_popup_menu(entries, title)
  return require("organ.popup_menu").pick(entries, {
    title = title,
    prompt = "Press key for an agenda command:",
  })
end

--- Open the agenda dispatcher menu (Emacs `C-c a`).  Style is controlled
--- by `config.agenda.dispatcher_style`:
---   "popup"  — single-keystroke menu in a floating window (default;
---              works under noice / snacks / native cmdline alike)
---   "echo"   — single-keystroke menu via nvim_echo + getchar
---              (terminal-classic; gets intercepted by some UI plugins)
---   "select" — `vim.ui.select` (telescope / dressing / snacks-pickers)
---   custom   — `config.agenda.dispatcher_handler({title, entries})`
function M.dispatch()
  local cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  local entries = build_dispatch_entries()

  local handler = cfg.dispatcher_handler
  if type(handler) == "function" then
    local data = {}
    for _, e in ipairs(entries) do
      data[#data + 1] = { key = e[1], label = e[2], action = e[3] }
    end
    handler({ title = "Agenda dispatcher", entries = data })
    return
  end

  if cfg.dispatcher_style == "select" then
    local labels = {}
    for _, e in ipairs(entries) do
      labels[#labels + 1] = string.format("%s   %s", e[1], e[2])
    end
    vim.ui.select(labels, { prompt = "Agenda dispatcher:" }, function(choice, idx)
      if not choice then
        return
      end
      if not idx then
        for i, l in ipairs(labels) do
          if l == choice then
            idx = i
            break
          end
        end
      end
      if not idx then
        return
      end
      local ok, err = pcall(entries[idx][3])
      if not ok then
        require("organ.notify").error("agenda: " .. tostring(err))
      end
    end)
    return
  end

  if cfg.dispatcher_style == "echo" then
    local lines = { "Press key for an agenda command:", "" }
    for _, e in ipairs(entries) do
      lines[#lines + 1] = string.format("  %s   %s", e[1], e[2])
    end
    vim.api.nvim_echo({ { table.concat(lines, "\n"), "Normal" } }, false, {})
    local ok, char = pcall(vim.fn.getcharstr)
    pcall(vim.cmd, "redraw")
    if not ok or not char or char == "" then
      return
    end
    for _, e in ipairs(entries) do
      if e[1] == char then
        local ok2, err = pcall(e[3])
        if not ok2 then
          require("organ.notify").error("agenda: " .. tostring(err))
        end
        return
      end
    end
    require("organ.notify").warn("organ: no agenda view bound to '" .. char .. "'")
    return
  end

  -- Default: floating-window popup.
  local action, char = show_popup_menu(entries, "Agenda dispatcher")
  if action then
    local ok, err = pcall(action)
    if not ok then
      require("organ.notify").error("agenda: " .. tostring(err))
    end
  elseif char and char ~= "" and char ~= "\27" and char ~= "\3" then
    -- Esc (\27) and Ctrl-C (\3) cancel silently; any other unmapped
    -- key reports so the user knows the menu didn't bind it.
    require("organ.notify").warn("organ: no agenda view bound to '" .. char .. "'")
  end
end

-- Exposed for tests; the only call site stays inside this module.
M._show_popup_menu = show_popup_menu

local function complete_agenda_views()
  local out = {}
  for k in pairs((require("organ.buf_config").read(nil, "agenda") or {}).views or {}) do
    out[#out + 1] = k
  end
  return out
end

-- :Org agenda custom <lua-expr> evaluates a Lua expression that returns
-- a view spec (matching M.normalize_view shape) and opens it.  Mirrors
-- Emacs `org-agenda-custom-commands` ad-hoc dispatch but inline.
local function open_custom_view(args)
  local expr = args or ""
  if expr == "" then
    require("organ.notify").warn(":Org agenda custom requires a Lua view-spec expression")
    return
  end
  local chunk, err = loadstring("return " .. expr)
  if not chunk then
    chunk, err = loadstring(expr)
  end
  if not chunk then
    require("organ.notify").error("invalid view-spec expression: " .. tostring(err))
    return
  end
  local ok, view = pcall(chunk)
  if not ok then
    require("organ.notify").error("view-spec evaluation failed: " .. tostring(view))
    return
  end
  if type(view) ~= "table" then
    require("organ.notify").error("view-spec must be a table; got " .. type(view))
    return
  end
  M.open(view, "custom")
end

-- :Org habits -- list every `:STYLE: habit` headline with status,
-- streak, and a consistency-graph row showing the last N days
-- (default 21).  Builds a popup buffer with the habits report.
local function open_habits_view(days_arg)
  local days = tonumber(days_arg) or 21
  local query = require("organ.query")
  local hab = require("organ.habit")
  local rep = require("organ.todo.repeater")

  local rows = query.habits({ days = days })
  if #rows == 0 then
    require("organ.notify").info("no habits found (no :STYLE: habit properties)")
    return
  end

  local today = dates.today_iso()
  local lines = { string.format("Habits -- %d days ending %s", days, today), "" }
  for _, r in ipairs(rows) do
    local repeater = nil
    if r.scheduled then
      repeater = rep.parse("<" .. r.scheduled:sub(2, -2) .. ">")
    end
    local info = {
      scheduled_date = r.scheduled_date and r.scheduled_date:sub(1, 10) or nil,
      period_days = hab.period_days(repeater),
      alarm_days = hab.alarm_days(repeater),
      completions = r.completions,
    }
    local glyph_row = hab.render_glyph_row(info, today, days)
    local status = hab.status(info, today)
    local streak = hab.streak(r.completions, info.period_days)
    lines[#lines + 1] = string.format(
      "  %s  %-12s  streak=%-3d  %s   %s",
      glyph_row,
      status,
      streak,
      r.title or "(untitled)",
      r.file_path
          and (vim.fn.fnamemodify(r.file_path, ":t") .. ":" .. tostring((r.line_start or 0) + 1))
        or ""
    )
  end

  local buf = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(buf, 0, -1, lines)
  vim.api.nvim_set_option_value("filetype", "organ-habits", { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = math.min(120, vim.o.columns - 4),
    height = math.min(#lines + 2, vim.o.lines - 4),
    row = 2,
    col = 2,
    border = "rounded",
    title = " Habits ",
  })
end

M.commands = {
  agenda = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      if args ~= "" then
        M.named_view(args)
      else
        M.dispatch()
      end
    end,
    nargs = "?",
    complete = complete_agenda_views,
    desc = "Open organ agenda (with optional named view)",
  },
  ["agenda day"] = {
    fn = function()
      M.day()
    end,
    desc = "Agenda for today (single-day window)",
  },
  ["agenda week"] = {
    fn = function()
      M.week()
    end,
    desc = "Agenda for the current week",
  },
  ["agenda todos"] = {
    fn = function()
      M.todos()
    end,
    desc = "Global TODO list across all org files",
  },
  ["agenda tags"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      M.tags(args ~= "" and args or nil)
    end,
    nargs = "?",
    desc = "Tag-query agenda view (Emacs org-match syntax)",
  },
  ["agenda search"] = {
    fn = function(cmd)
      local args = cmd and cmd.args or ""
      M.search(args ~= "" and args or nil)
    end,
    nargs = "?",
    desc = "Title-substring search agenda view",
  },
  ["agenda custom"] = {
    fn = function(cmd)
      open_custom_view(cmd and cmd.args)
    end,
    nargs = "+",
    desc = "Open an ad-hoc view from a Lua expression (like Emacs org-agenda-custom-commands)",
  },
  stuck_projects = {
    fn = function()
      M.stuck()
    end,
    desc = "Open agenda buffer with stuck projects",
  },
  habits = {
    fn = function(cmd)
      open_habits_view(cmd and cmd.args)
    end,
    nargs = "?",
    desc = "Habits view (consistency graph + streaks; arg = days, default 21)",
  },
}

return M
