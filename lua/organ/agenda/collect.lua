-- Agenda record collection: resolves agenda file specs and runs per-block
-- queries, producing annotated record rows for the renderer.

local M = {}

local dates = require("organ.agenda.dates")

local function annotate_clocked_minutes(rows)
  local cfg_effort = (require("organ.buf_config").read(nil, "effort") or {})
  if cfg_effort.show_in_agenda == false then
    return rows
  end
  local effort = require("organ.effort")
  local needs = {}
  for _, r in ipairs(rows) do
    if effort.row_effort_minutes(r) then
      needs[#needs + 1] = r
    end
  end
  if #needs == 0 then
    return rows
  end
  local query = require("organ.query")
  for _, r in ipairs(needs) do
    local ok, entries = pcall(query.clock_entries, {
      headline_id = r.id,
      group_by = "headline",
    })
    if ok and entries and entries[1] and entries[1].duration_seconds then
      r.clocked_minutes = effort.clocked_minutes({ entries[1] })
    end
  end
  return rows
end

local function annotate_habits(rows)
  if #rows == 0 then
    return rows
  end
  local habit = require("organ.habit")
  local repeater = require("organ.todo.repeater")
  local query = require("organ.query")
  local habit_ids = {}
  for _, r in ipairs(rows) do
    if r.properties and habit.is_habit(r.properties) then
      r.is_habit = true
      habit_ids[#habit_ids + 1] = r.id
      local rep = r.scheduled and repeater.parse(r.scheduled) or nil
      if rep then
        r.habit_period_days = habit.period_days(rep)
        r.habit_alarm_days = habit.alarm_days(rep)
      end
    end
  end
  if #habit_ids > 0 then
    local today = dates.today_iso()
    local from = os.date("%Y-%m-%d", dates.now_ts() - 13 * 86400)
    local comps = query.habit_completions({ headline_id = habit_ids, from = from, to = today })
    for _, r in ipairs(rows) do
      if r.is_habit then
        r.completions = comps[r.id] or {}
        r._today = today
      end
    end
  end
  return rows
end

-- Resolve `agenda_files` config (or per-block override) to a list of
-- canonical file paths.  Mirrors Emacs's `org-agenda-files` and
-- nvim-orgmode's glob-style at the same time:
--
--   nil               -> no restriction (every indexed file)
--   "~/org/todo.org"  -> single file
--   "~/org"           -> directory; top-level `.org` / `.org_archive`
--                       files only (Emacs's "list-with-a-directory")
--   "~/org/**/*.org"  -> vim glob; expanded recursively (the `**` and
--                       `*` make it a glob; nvim-orgmode's shape).
--                       Detected by presence of `*`, `?`, or `[`.
--   { "~/org/*.org",
--     "!~/org/private/*" }
--                     -> list of strings.  An entry starting with `!`
--                       is an EXCLUSION glob applied to the union of
--                       everything else.  So you can say "all org
--                       files except these" without writing a
--                       function.
--   function          -> called at resolve time; must return any of
--                       the above shapes (string, list, or another
--                       function -- recursively resolved).  This is
--                       the full escape hatch when the user wants
--                       arbitrary include / exclude logic.  The
--                       built-in `organ.agenda.recurse_dir(path)`
--                       returns one such function.
local function resolve_one(entry, includes, excludes)
  if type(entry) == "function" then
    -- Recursively resolve whatever the function returns.
    local nested = entry()
    if type(nested) == "string" then
      resolve_one(nested, includes, excludes)
    elseif type(nested) == "table" then
      for _, e in ipairs(nested) do
        resolve_one(e, includes, excludes)
      end
    end
    return
  end
  if type(entry) ~= "string" then
    return
  end
  local exclude = false
  if entry:sub(1, 1) == "!" then
    exclude = true
    entry = entry:sub(2)
  end
  local target = exclude and excludes or includes
  -- Detect glob meta-chars on the ORIGINAL string before expansion --
  -- `vim.fn.expand` is itself a globbing call, so pre-expanding here
  -- would silently consume the wildcards.  `vim.fn.glob` handles `~` /
  -- env-var expansion alongside `*` / `?` / `[` / `**` matching.
  if entry:match("[*?%[]") then
    local matches = vim.fn.glob(entry, false, true)
    for _, m in ipairs(matches) do
      if m:match("%.org$") or m:match("%.org_archive$") then
        target[#target + 1] = m
      end
    end
    return
  end
  -- Non-glob: file or directory.  Stat to discriminate.
  local p = vim.fn.expand(entry)
  local stat = vim.uv.fs_stat(p)
  if not stat then
    return
  end
  if stat.type == "directory" then
    local h = vim.uv.fs_scandir(p)
    if not h then
      return
    end
    while true do
      local name, t = vim.uv.fs_scandir_next(h)
      if not name then
        break
      end
      if
        (t == "file" or t == "link")
        and (name:match("%.org$") or name:match("%.org_archive$"))
      then
        target[#target + 1] = p .. "/" .. name
      end
    end
  else
    target[#target + 1] = p
  end
end

function M.resolve_agenda_files(spec)
  if spec == nil then
    return nil
  end
  local includes, excludes = {}, {}
  if type(spec) == "function" or type(spec) == "string" then
    resolve_one(spec, includes, excludes)
  elseif type(spec) == "table" then
    for _, entry in ipairs(spec) do
      resolve_one(entry, includes, excludes)
    end
  else
    return nil
  end
  if #excludes == 0 then
    return includes
  end
  -- Subtract excludes from includes (set difference).
  local excluded = {}
  for _, p in ipairs(excludes) do
    excluded[p] = true
  end
  local out = {}
  for _, p in ipairs(includes) do
    if not excluded[p] then
      out[#out + 1] = p
    end
  end
  return out
end

-- Initial row fetch for non-time-window views (search / tags / todo),
-- including the TODO-list ignore filters (Emacs `org-agenda-todo-ignore-*`
-- and `org-agenda-todo-list-sublevels`).
local function fetch_headline_rows(block, query, files, cfg_disp)
  local rows = query.headlines({
    title_match = block.title_match,
    todo = block.todo,
    tags = block.tags,
    priority = block.priority,
    files = files,
    include_properties = true,
    include_inherited_tags = cfg_disp,
  })
  -- TODO-list view filters (mirror Emacs `org-agenda-todo-ignore-*`
  -- and `org-agenda-todo-list-sublevels`).  Per-block override beats
  -- the global defaults so a single view can opt in/out.
  -- todo-ignore filters apply to the TODO-list view always, and to
  -- the tag-search view when `tags_todo_honor_ignore_options = true`
  -- (Emacs `org-agenda-tags-todo-honor-ignore-options`).  Per-block
  -- override beats the global defaults.
  local ag = require("organ.buf_config").read(nil, "agenda") or {}
  local function pick(name)
    if block[name] ~= nil then
      return block[name]
    end
    return ag[name]
  end
  local apply_filters = (block.kind == "todo")
  if block.kind == "tags" and pick("tags_todo_honor_ignore_options") then
    apply_filters = true
  end
  if apply_filters then
    local ignore_sched = pick("todo_ignore_scheduled")
    local ignore_dead = pick("todo_ignore_deadlines")
    local ignore_dated = pick("todo_ignore_with_date")
    local sublevels = pick("todo_list_sublevels")
    if sublevels == nil then
      sublevels = true
    end
    if ignore_sched or ignore_dead or ignore_dated or sublevels == false then
      local kept = {}
      for _, r in ipairs(rows) do
        local skip = false
        if sublevels == false and (r.level or 1) > 1 then
          skip = true
        end
        if ignore_sched and r.scheduled_date and r.scheduled_date ~= "" then
          skip = true
        end
        if ignore_dead and r.deadline_date and r.deadline_date ~= "" then
          skip = true
        end
        if
          ignore_dated
          and (
            (r.scheduled_date and r.scheduled_date ~= "")
            or (r.deadline_date and r.deadline_date ~= "")
          )
        then
          skip = true
        end
        if not skip then
          kept[#kept + 1] = r
        end
      end
      rows = kept
    end
  end
  return rows
end

-- Skip COMMENT trees (Emacs `org-agenda-skip-comment-trees`).  A
-- headline of the form `* COMMENT Foo` or `* TODO COMMENT Foo`
-- excludes the entire subtree from the agenda.  Default `true`
-- (Emacs default).  Per-block override via `block.skip_comment_trees`.
--
-- Implementation: build the set of commented headline IDs from the
-- rows we have, then walk parent_id chains transitively so any
-- descendant of a commented heading is also dropped.  Some rows
-- come from `query.agenda`'s repeater-projection path and may carry
-- only the headline (no parent_id chain), so we look up the parent
-- chain in the DB on demand.
local function skip_comment_trees(block, rows)
  local agenda_cfg_c = (require("organ.buf_config").read(nil, "agenda") or {})
  local skip_c
  if block.skip_comment_trees ~= nil then
    skip_c = block.skip_comment_trees
  else
    skip_c = agenda_cfg_c.skip_comment_trees
  end
  if skip_c == nil then
    skip_c = true
  end
  if not skip_c then
    return rows
  end
  local query2 = require("organ.query")
  local commented_cache = {}
  local function is_commented_chain(id)
    if not id or id == "" then
      return false
    end
    if commented_cache[id] ~= nil then
      return commented_cache[id]
    end
    local rec = query2.get_by_id(id)
    if not rec then
      commented_cache[id] = false
      return false
    end
    if rec.commented then
      commented_cache[id] = true
      return true
    end
    local up = is_commented_chain(rec.parent_id)
    commented_cache[id] = up
    return up
  end
  local kept = {}
  for _, r in ipairs(rows) do
    local skip = r.commented or is_commented_chain(r.parent_id)
    if not skip then
      kept[#kept + 1] = r
    end
  end
  return kept
end

-- Per-type skip rules (Emacs `org-agenda-skip-scheduled-if-done`,
-- `org-agenda-skip-deadline-if-done`). Finer than blanket
-- todo.exclude -- a row may be DONE for its scheduled date but still
-- want surfacing under its deadline (or vice versa). Done-keyword
-- detection comes from the configured todo sequence.
local function skip_done_by_type(rows)
  local agenda_cfg2 = (require("organ.buf_config").read(nil, "agenda") or {})
  if not (agenda_cfg2.skip_scheduled_if_done or agenda_cfg2.skip_deadline_if_done) then
    return rows
  end
  -- Per-row done classification.  Files may declare their own
  -- `#+TODO:` directive that overrides global done keywords for
  -- their headlines (Emacs behavior).  Single batched DB query
  -- against the `file_todo_keywords` index -- no per-row file I/O.
  local cfg_seq = (require("organ.buf_config").read(nil, "todo") or {}).sequences
    or (require("organ.buf_config").read(nil, "todo") or {}).sequence
    or {}
  local global_done = {}
  for _, seq in ipairs(require("organ.todo")._normalise_sequences(cfg_seq)) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      elseif in_done then
        global_done[k] = true
      end
    end
  end
  local seen_paths, paths = {}, {}
  for _, r in ipairs(rows) do
    if r.file_path and not seen_paths[r.file_path] then
      seen_paths[r.file_path] = true
      paths[#paths + 1] = r.file_path
    end
  end
  local q = require("organ.query")
  local file_kw = (#paths > 0 and type(q.file_todo_keywords) == "function")
      and q.file_todo_keywords(paths)
    or {}
  -- For files open as modified buffers, the on-disk index is
  -- stale until BufWritePost re-runs the scan.  Override
  -- per-buffer with a live scan so a user editing a `#+TODO:`
  -- line sees correct done classification immediately.  Bounded:
  -- only fires when a buffer is BOTH loaded AND `&modified`,
  -- and only scans the first ~200 lines (where directives live).
  local todo = require("organ.todo")
  local live_overrides = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and seen_paths[name] then
        local seqs = todo.buffer_sequences(b)
        if seqs then
          local active, done = {}, {}
          for _, seq in ipairs(seqs) do
            local in_done = false
            for _, k in ipairs(seq) do
              if k == "|" then
                in_done = true
              elseif in_done then
                done[k] = true
              else
                active[k] = true
              end
            end
          end
          live_overrides[name] = { active = active, done = done }
        end
      end
    end
  end
  local function done_set_for(file_path)
    local live = file_path and live_overrides[file_path]
    if live then
      return live.done
    end
    local entry = file_path and file_kw[file_path]
    if entry then
      return entry.done
    end
    return global_done
  end
  local kept = {}
  for _, r in ipairs(rows) do
    local file_done = done_set_for(r.file_path)
    local is_done = r.todo_state and file_done[r.todo_state] == true
    local has_sched = r.scheduled_date and r.scheduled_date ~= ""
    local has_dead = r.deadline_date and r.deadline_date ~= ""
    local skip = false
    if is_done then
      if agenda_cfg2.skip_scheduled_if_done and has_sched and not has_dead then
        skip = true
      end
      if agenda_cfg2.skip_deadline_if_done and has_dead and not has_sched then
        skip = true
      end
    end
    if not skip then
      kept[#kept + 1] = r
    end
  end
  return kept
end

-- Overdue scheduled items: a row scheduled BEFORE block.from won't
-- be in the in-window query result. Opt-in via
-- `agenda.show_overdue_scheduled = true` (matches Emacs default of
-- NOT rolling these up). When on, fetch the overdue rows and the
-- bucketing loop in render_block reroutes them to today's bucket.
local function append_overdue_scheduled(block, rows, query, files, cfg_disp)
  local show_overdue_sched = (require("organ.buf_config").read(nil, "agenda") or {}).show_overdue_scheduled
    == true
  if not (show_overdue_sched and block.from) then
    return rows
  end
  local from_iso = query.parse_date and query.parse_date(block.from) or block.from
  local overdue_rows = query.agenda({
    from = "1900-01-01",
    to = from_iso,
    types = { "scheduled" },
    todo = block.todo,
    tags = block.tags,
    priority = block.priority,
    title_match = block.title_match,
    files = files,
    include_properties = true,
    include_inherited_tags = cfg_disp,
  })
  local seen = {}
  for _, r in ipairs(rows) do
    if r.id then
      seen[r.id] = true
    end
  end
  for _, r in ipairs(overdue_rows or {}) do
    local rd = dates.date_only(r.scheduled_date)
    if rd and rd < from_iso and not seen[r.id] then
      rows[#rows + 1] = r
    end
  end
  return rows
end

-- Tag-query view: filter rows through the org-match predicate.
local function filter_tag_match(block, rows)
  if not (block.kind == "tags" and block.tag_match and block.tag_match ~= "") then
    return rows
  end
  local ok, match = pcall(require, "organ.match")
  if ok and match.predicate then
    local pred = match.predicate(block.tag_match)
    local filtered = {}
    for _, r in ipairs(rows) do
      if pred(r) then
        filtered[#filtered + 1] = r
      end
    end
    rows = filtered
  end
  return rows
end

-- Diary-sexp synthetic rows (opt-in via config.agenda.include_diary_sexp).
-- Resolves block.from / block.to to ISO via query.parse_date so the day
-- iterator can step through; honors `block.types` allowing scheduled-like
-- entries to flow into the same render.
local function append_diary_sexp(block, rows, query)
  local agenda_cfg = (require("organ.buf_config").read(nil, "agenda") or {})
  if agenda_cfg.include_diary_sexp and block.from and block.to then
    local from_iso = query.parse_date(block.from)
    local to_iso = query.parse_date(block.to)
    if from_iso and to_iso then
      local extra = require("organ.diary_sexp").agenda_rows(from_iso, to_iso)
      for _, r in ipairs(extra) do
        rows[#rows + 1] = r
      end
    end
  end
  return rows
end

-- Log mode (Emacs `org-agenda-log-mode`).  When active, fetch
-- closed/clocked/state-changed events whose date falls inside the
-- visible window and inject them as synthetic rows under the day
-- each event happened.  All three event types live in the index
-- (closed_date column, clock_entries table, state_changes table)
-- so this is a SQL-only fanout -- no per-file rescan.
local function append_log_mode(block, rows, query)
  local log_mode = block._log_mode_active
  if not (log_mode and block.from and block.to) then
    return rows
  end
  local items_set = {}
  for _, it in ipairs(block.log_mode_items or { "closed", "clock" }) do
    items_set[it] = true
  end
  local from_iso = query.parse_date(block.from) or block.from
  local to_iso = query.parse_date(block.to) or block.to

  if items_set.closed then
    local closed_rows = query.headlines({
      closed = { from = from_iso, to = to_iso },
      include_properties = false,
    }) or {}
    local seen = {}
    for _, r in ipairs(rows) do
      if r.id then
        seen[r.id] = true
      end
    end
    for _, r in ipairs(closed_rows) do
      if r.id and not seen[r.id] and r.closed_date then
        r._bucket_date = dates.date_only(r.closed_date)
        r._log_mode = "closed"
        rows[#rows + 1] = r
      end
    end
  end

  if items_set.clock then
    local clk_rows = query.clock_entries({
      from = from_iso,
      to = to_iso,
      group_by = "headline_day",
      include_active = true,
    }) or {}
    for _, c in ipairs(clk_rows) do
      local hl = query.get_by_id(c.headline_id)
      if hl then
        local mins = math.floor((c.total_seconds or 0) / 60)
        local synthetic = vim.tbl_extend("force", hl, {
          _bucket_date = c.day,
          _log_mode = "clock",
          _log_clock_minutes = mins,
        })
        rows[#rows + 1] = synthetic
      end
    end
  end

  if items_set.state then
    local sc_rows = query.state_changes({ from = from_iso, to = to_iso }) or {}
    for _, sc in ipairs(sc_rows) do
      if sc.headline_id then
        local hl = query.get_by_id(sc.headline_id)
        if hl then
          local synthetic = vim.tbl_extend("force", hl, {
            _bucket_date = sc.day,
            _log_mode = "state",
            _log_state_from = sc.from_state,
            _log_state_to = sc.to_state,
            _log_state_ts = sc.ts,
          })
          rows[#rows + 1] = synthetic
        end
      end
    end
  end
  return rows
end

local function run_query(block)
  if block.kind == "stuck" then
    local cfg = (require("organ.buf_config").read(nil, "stuck") or {})
    return require("organ.query").stuck_projects({
      project_filter = block.project_filter or cfg.project_filter,
      next_states = block.next_states or cfg.next_states,
    })
  end
  local query = require("organ.query")
  local cfg_disp = (require("organ.buf_config").read(nil, "tags") or {}).display_inherited
  -- Per-block `files` overrides the global `agenda_files` config.
  -- nil at both levels -> no file filter (every indexed file).
  local files_spec = block.files or require("organ.buf_config").read(nil, "agenda_files")
  local files = files_spec and M.resolve_agenda_files(files_spec) or nil
  local rows
  if block.kind == "search" or block.kind == "tags" or block.kind == "todo" then
    rows = fetch_headline_rows(block, query, files, cfg_disp)
  else
    rows = query.agenda({
      from = block.from,
      to = block.to,
      types = block.types,
      todo = block.todo,
      tags = block.tags,
      priority = block.priority,
      title_match = block.title_match,
      files = files,
      include_properties = true,
      include_inherited_tags = cfg_disp,
    })
  end

  rows = skip_comment_trees(block, rows)
  rows = skip_done_by_type(rows)
  rows = append_overdue_scheduled(block, rows, query, files, cfg_disp)
  rows = filter_tag_match(block, rows)
  rows = append_diary_sexp(block, rows, query)
  rows = append_log_mode(block, rows, query)
  return annotate_habits(annotate_clocked_minutes(rows))
end

M.run_query = run_query

return M
