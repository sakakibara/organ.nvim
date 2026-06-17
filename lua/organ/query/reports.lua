-- Aggregate and report queries: stuck projects, indexed files, per-file TODO
-- keywords, habit completions and stats, clock entries, state changes.

local M = {}

local exec = require("organ.query.exec")

-- Returns headlines matching project_filter that have NO direct child whose
-- todo_state is in next_states. Pure read; no DB writes.
function M.stuck_projects(opts)
  opts = opts or {}
  local cfg = (require("organ.buf_config").read(nil, "stuck") or {})
  local project_filter = opts.project_filter
    or cfg.project_filter
    or { tags = { any = { "project" } } }
  local next_states = opts.next_states or cfg.next_states or { "NEXT" }

  -- When the filter specifies tags without an explicit inherit setting,
  -- disable tag inheritance so that only directly-tagged headlines are
  -- returned as project candidates (children that inherit the tag should
  -- not themselves be treated as projects).
  local effective_filter = vim.tbl_deep_extend("force", {}, project_filter)
  if
    effective_filter.tags
    and type(effective_filter.tags) == "table"
    and effective_filter.tags.inherit == nil
  then
    effective_filter.tags = vim.tbl_deep_extend("force", {}, effective_filter.tags)
    effective_filter.tags.inherit = false
  end

  -- Through the facade: organ.query requires this module at load time, and facade dispatch keeps test stubs effective.
  local projects = require("organ.query").headlines(effective_filter)
  if #projects == 0 then
    return {}
  end

  local h = exec.default_db()

  -- Build a single SQL query that returns parent_ids that DO have an active child.
  local placeholders = {}
  for _ = 1, #next_states do
    placeholders[#placeholders + 1] = "?"
  end
  local sql = string.format(
    [[
    SELECT DISTINCT parent_id
      FROM headlines
     WHERE parent_id IS NOT NULL
       AND todo_state IN (%s)
  ]],
    table.concat(placeholders, ",")
  )
  local s = exec.prepare(h, sql)
  for i, st in ipairs(next_states) do
    s:bind_text(i, st)
  end
  local db = require("organ.db")
  local active_parents = {}
  while s:step() == db.SQLITE_ROW do
    active_parents[s:column_text(0)] = true
  end
  s:finalize()

  local stuck = {}
  for _, p in ipairs(projects) do
    if not active_parents[p.id] then
      stuck[#stuck + 1] = p
    end
  end
  return stuck
end

-- Returns one record per indexed org file:
--   { file_path, basename, headline_count, last_indexed }
-- Sorted by basename asc.
function M.files(opts)
  opts = opts or {}
  local h = exec.resolve_db(opts)
  local sql = [[
    SELECT f.path AS file_path, COUNT(hl.id) AS headline_count, f.indexed AS last_indexed
      FROM files f
      LEFT JOIN headlines hl ON hl.file_path = f.path
     GROUP BY f.path
     ORDER BY f.path
  ]]
  local s = exec.prepare(h, sql)
  local db = require("organ.db")
  local rows = {}
  while s:step() == db.SQLITE_ROW do
    local path = s:column_text(0)
    rows[#rows + 1] = {
      file_path = path,
      basename = vim.fn.fnamemodify(path, ":t"),
      headline_count = s:column_int(1),
      last_indexed = s:column_int(2),
    }
  end
  s:finalize()
  table.sort(rows, function(a, b)
    return a.basename < b.basename
  end)
  return rows
end

-- Map file_path -> { active = {KW=true,...}, done = {KW=true,...} }
-- for the given list of file paths, derived from the per-file
-- `#+TODO:` directive index in `file_todo_keywords`.  Files that
-- have no directive entries are simply absent from the returned
-- map.  Used by the agenda's per-row done classification (so it
-- doesn't have to re-read source files).
function M.file_todo_keywords(file_paths, opts)
  opts = opts or {}
  if not file_paths or #file_paths == 0 then
    return {}
  end
  local h = exec.resolve_db(opts)
  -- Build a parameterised IN list (one `?` per path).
  local placeholders = {}
  for i = 1, #file_paths do
    placeholders[i] = "?"
  end
  local sql = "SELECT file_path, keyword, is_done FROM file_todo_keywords"
    .. " WHERE file_path IN ("
    .. table.concat(placeholders, ",")
    .. ")"
  local s = exec.prepare(h, sql)
  for i, path in ipairs(file_paths) do
    s:bind_text(i, path)
  end
  local db = require("organ.db")
  local out = {}
  while s:step() == db.SQLITE_ROW do
    local path = s:column_text(0)
    local kw = s:column_text(1)
    local is_done = s:column_int(2) == 1
    if not out[path] then
      out[path] = { active = {}, done = {} }
    end
    if is_done then
      out[path].done[kw] = true
    else
      out[path].active[kw] = true
    end
  end
  s:finalize()
  return out
end

-- Habit-completion dates for one or more headlines.
-- opts = { headline_id (string or list), from = "yyyy-mm-dd", to = "yyyy-mm-dd" }
-- Returns:
--   if opts.headline_id is a single string:
--     ascending-sorted list of "yyyy-mm-dd" strings
--   if opts.headline_id is a list (or nil):
--     map { headline_id -> list of dates }
function M.habit_completions(opts)
  opts = opts or {}
  local h = exec.resolve_db(opts)
  if not h then
    return {}
  end

  local where, params = {}, {}
  local single_id = nil
  if type(opts.headline_id) == "string" then
    where[#where + 1] = "headline_id = ?"
    params[#params + 1] = opts.headline_id
    single_id = opts.headline_id
  elseif type(opts.headline_id) == "table" and #opts.headline_id > 0 then
    local placeholders = {}
    for _, id in ipairs(opts.headline_id) do
      placeholders[#placeholders + 1] = "?"
      params[#params + 1] = id
    end
    where[#where + 1] = "headline_id IN (" .. table.concat(placeholders, ",") .. ")"
  end
  if opts.from then
    where[#where + 1] = "date >= ?"
    params[#params + 1] = opts.from
  end
  if opts.to then
    where[#where + 1] = "date <= ?"
    params[#params + 1] = opts.to
  end
  local sql = "SELECT headline_id, date FROM habit_completions"
  if #where > 0 then
    sql = sql .. " WHERE " .. table.concat(where, " AND ")
  end
  sql = sql .. " ORDER BY headline_id, date"

  local s, err = h:prepare(sql)
  if not s then
    return {}
  end
  for i, p in ipairs(params) do
    s:bind_text(i, p)
  end
  local db = require("organ.db")
  local result = {}
  while s:step() == db.SQLITE_ROW do
    local id = s:column_text(0)
    local date = s:column_text(1)
    if not result[id] then
      result[id] = {}
    end
    result[id][#result[id] + 1] = date
  end
  s:finalize()

  if single_id then
    return result[single_id] or {}
  end
  return result
end

-- All headlines marked `:STYLE: habit`, sorted by file then line.
-- Each row carries the same shape as M.headlines plus `completions` (the
-- last `days` days of completion dates) and `is_habit = true`.
function M.habits(opts)
  opts = opts or {}
  local days = opts.days or 21
  local h = exec.resolve_db(opts)
  if not h then
    return {}
  end
  local sql = [[
    SELECT DISTINCT hl.id
      FROM headlines hl
      JOIN properties p ON p.headline_id = hl.id
     WHERE upper(p.key)   = 'STYLE'
       AND lower(p.value) = 'habit'
  ]]
  local s = exec.prepare(h, sql)
  local db = require("organ.db")
  local ids = {}
  while s:step() == db.SQLITE_ROW do
    ids[#ids + 1] = s:column_text(0)
  end
  s:finalize()

  if #ids == 0 then
    return {}
  end

  -- Pull headline rows for those IDs.
  local rows = {}
  for _, id in ipairs(ids) do
    local r = require("organ.query").get_by_id(id, { db = h })
    if r then
      rows[#rows + 1] = r
    end
  end

  -- Attach completions.
  local today = os.date("%Y-%m-%d")
  local from = os.date("%Y-%m-%d", os.time() - (days - 1) * 86400)
  local comp_map = M.habit_completions({ headline_id = ids, from = from, to = today, db = h })
  for _, r in ipairs(rows) do
    r.is_habit = true
    r.completions = comp_map[r.id] or {}
  end

  table.sort(rows, function(a, b)
    if a.file_path ~= b.file_path then
      return (a.file_path or "") < (b.file_path or "")
    end
    return (a.line_start or 0) < (b.line_start or 0)
  end)
  return rows
end

-- Returns clock-time rows grouped per the spec.
-- opts = { from, to, headline_id, file, group_by, include_active }
function M.clock_entries(opts)
  opts = opts or {}
  local h = exec.default_db()
  if not h then
    return {}
  end

  local function day_start(date_str)
    local y, mo, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then
      return nil
    end
    return os.time({
      year = tonumber(y),
      month = tonumber(mo),
      day = tonumber(d),
      hour = 0,
      min = 0,
      sec = 0,
    })
  end
  local from_ts = opts.from and day_start(opts.from) or 0
  local to_ts = opts.to and (day_start(opts.to) + 86400 - 1) or 2 ^ 31 - 1
  if from_ts > to_ts then
    from_ts, to_ts = to_ts, from_ts
  end

  local active_dur = (opts.include_active == true)
      and string.format("CASE WHEN ce.end_ts IS NULL THEN (%d - ce.start_ts) ELSE 0 END", os.time())
    or "0"
  local closed_filter = (opts.include_active == true) and "" or " AND ce.end_ts IS NOT NULL"

  local where = { "ce.start_ts BETWEEN ? AND ?" }
  local params = { from_ts, to_ts }
  if opts.headline_id then
    where[#where + 1] = "ce.headline_id = ?"
    params[#params + 1] = opts.headline_id
  end
  if opts.file then
    where[#where + 1] = "h.file_path = ?"
    local canon = require("organ.path").canonical(opts.file)
    params[#params + 1] = canon or opts.file
  end
  local where_sql = table.concat(where, " AND ") .. closed_filter

  local group_by = opts.group_by or "headline"
  local select_sql, group_sql, order_sql
  if group_by == "headline" then
    select_sql = "ce.headline_id AS headline_id, h.title AS title, h.file_path AS file_path, "
      .. "SUM(COALESCE(ce.duration_seconds, 0) + "
      .. active_dur
      .. ") AS total_seconds"
    group_sql = "GROUP BY ce.headline_id"
    order_sql = "ORDER BY total_seconds DESC"
  elseif group_by == "day" then
    select_sql = "DATE(ce.start_ts, 'unixepoch') AS day, "
      .. "SUM(COALESCE(ce.duration_seconds, 0) + "
      .. active_dur
      .. ") AS total_seconds"
    group_sql = "GROUP BY day"
    order_sql = "ORDER BY day"
  elseif group_by == "headline_day" then
    select_sql = "ce.headline_id AS headline_id, h.title AS title, "
      .. "DATE(ce.start_ts, 'unixepoch') AS day, "
      .. "SUM(COALESCE(ce.duration_seconds, 0) + "
      .. active_dur
      .. ") AS total_seconds"
    group_sql = "GROUP BY ce.headline_id, day"
    order_sql = "ORDER BY day, total_seconds DESC"
  else
    error("query.clock_entries: unknown group_by " .. tostring(group_by))
  end

  local sql = "SELECT "
    .. select_sql
    .. " FROM clock_entries ce LEFT JOIN headlines h ON h.id = ce.headline_id"
    .. " WHERE "
    .. where_sql
    .. " "
    .. group_sql
    .. " "
    .. order_sql

  local stmt = exec.prepare(h, sql)
  for i, p in ipairs(params) do
    if type(p) == "number" then
      stmt:bind_int(i, p)
    else
      stmt:bind_text(i, p)
    end
  end
  local db = require("organ.db")
  local rows = {}
  while stmt:step() == db.SQLITE_ROW do
    local row = {}
    if group_by == "headline" then
      row.headline_id = stmt:column_text(0)
      row.title = stmt:column_text(1)
      row.file_path = stmt:column_text(2)
      row.total_seconds = stmt:column_int(3)
    elseif group_by == "day" then
      row.day = stmt:column_text(0)
      row.total_seconds = stmt:column_int(1)
    elseif group_by == "headline_day" then
      row.headline_id = stmt:column_text(0)
      row.title = stmt:column_text(1)
      row.day = stmt:column_text(2)
      row.total_seconds = stmt:column_int(3)
    end
    rows[#rows + 1] = row
  end
  stmt:finalize()
  return rows
end

-- State-change rows from LOGBOOK drawers, joined to their headline
-- so the agenda log mode can render `State: TODO -> DONE` lines on
-- the day each change happened.
--
-- opts = { from = "YYYY-MM-DD", to = "YYYY-MM-DD", headline_id, file }
-- Returns: list of { ts, day = "YYYY-MM-DD", from_state, to_state,
-- note, headline_id, title, file_path, line_start } sorted by ts.
function M.state_changes(opts)
  opts = opts or {}
  local h = exec.default_db()
  if not h then
    return {}
  end
  local function day_start(date_str)
    local y, mo, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then
      return nil
    end
    return os.time({
      year = tonumber(y),
      month = tonumber(mo),
      day = tonumber(d),
      hour = 0,
      min = 0,
      sec = 0,
    })
  end
  local from_ts = opts.from and day_start(opts.from) or 0
  local to_ts = opts.to and (day_start(opts.to) + 86400 - 1) or 2 ^ 31 - 1
  if from_ts > to_ts then
    from_ts, to_ts = to_ts, from_ts
  end

  local where = { "sc.ts BETWEEN ? AND ?" }
  local params = { from_ts, to_ts }
  if opts.headline_id then
    where[#where + 1] = "sc.headline_id = ?"
    params[#params + 1] = opts.headline_id
  end
  if opts.file then
    where[#where + 1] = "h.file_path = ?"
    local canon = require("organ.path").canonical(opts.file)
    params[#params + 1] = canon or opts.file
  end

  local sql = "SELECT sc.ts, sc.from_state, sc.to_state, sc.note, "
    .. "sc.headline_id, h.title, h.file_path, h.line_start "
    .. "FROM state_changes sc LEFT JOIN headlines h ON h.id = sc.headline_id "
    .. "WHERE "
    .. table.concat(where, " AND ")
    .. " ORDER BY sc.ts ASC"

  local stmt = exec.prepare(h, sql)
  for i, p in ipairs(params) do
    if type(p) == "number" then
      stmt:bind_int(i, p)
    else
      stmt:bind_text(i, p)
    end
  end
  local db = require("organ.db")
  local rows = {}
  while stmt:step() == db.SQLITE_ROW do
    local ts = stmt:column_int(0)
    rows[#rows + 1] = {
      ts = ts,
      day = os.date("%Y-%m-%d", ts),
      from_state = stmt:column_text(1),
      to_state = stmt:column_text(2),
      note = stmt:column_text(3),
      headline_id = stmt:column_text(4),
      title = stmt:column_text(5),
      file_path = stmt:column_text(6),
      line_start = stmt:column_int(7),
    }
  end
  stmt:finalize()
  return rows
end

return M
