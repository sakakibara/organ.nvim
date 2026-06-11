-- Query layer for organ.nvim. Pure functions over an existing DB handle.
--
-- Main entry points (all return an array of headline records):
--   query.headlines(filters)         -- catch-all, every filter optional
--   query.agenda(opts)               -- convenience over scheduled+deadline windows
--   query.by_tag(tags, opts)         -- convenience over { tags = { any = ... } }
--   query.by_todo(states, opts)      -- convenience over { todo = states }
--   query.by_file(path, opts)        -- convenience over { file = path }
--
-- All functions take the DB handle from `require("organ.runtime").db()`. Callers who
-- need to query across multiple handles can pass their own via opts.db.

local M = {}

local dates = require("organ.query.dates")
local sql = require("organ.query.sql")

M.parse_date = dates.parse_date
-- The SQL builder keeps its historical seam name on the facade:
-- query_builder_test calls _build_sql, and M.headlines dispatches through it.
M._build_sql = sql.build

-- Execution helpers.

local function default_db()
  return require("organ.runtime").db()
end

local function rows_from_select(h, sql, params)
  local stmt, err = h:prepare(sql)
  if not stmt then
    error("query prepare failed: " .. tostring(err))
  end
  for i, p in ipairs(params) do
    if type(p) == "number" then
      stmt:bind_int(i, p)
    elseif p == nil then
      stmt:bind_null(i)
    else
      stmt:bind_text(i, tostring(p))
    end
  end

  local db = require("organ.db")
  local rows = {}
  while true do
    local rc = stmt:step()
    if rc == db.SQLITE_ROW then
      rows[#rows + 1] = {
        id = stmt:column_text(0),
        file_path = stmt:column_text(1),
        parent_id = stmt:column_text(2),
        level = stmt:column_int(3),
        title = stmt:column_text(4),
        todo_state = stmt:column_text(5),
        priority = stmt:column_text(6),
        scheduled = stmt:column_text(7),
        deadline = stmt:column_text(8),
        closed = stmt:column_text(9),
        scheduled_date = stmt:column_text(10),
        deadline_date = stmt:column_text(11),
        closed_date = stmt:column_text(12),
        line_start = stmt:column_int(13),
        line_end = stmt:column_int(14),
        commented = stmt:column_int(15) == 1,
        tags = {},
      }
    elseif rc == db.SQLITE_DONE then
      break
    else
      stmt:finalize()
      error("query step failed rc=" .. rc)
    end
  end
  stmt:finalize()
  return rows
end

local function hydrate_tags(h, rows)
  if #rows == 0 then
    return
  end
  local id_to_row = {}
  local placeholders = {}
  local params = {}
  for i, r in ipairs(rows) do
    id_to_row[r.id] = r
    placeholders[i] = "?"
    params[i] = r.id
  end

  -- ORDER BY rowid so tags come back in insertion (= file-source) order.
  -- Without this, SQLite's PRIMARY KEY (headline_id, tag) index returns
  -- tags alphabetically, which breaks Emacs-style display where users
  -- expect `:gtd:@phone:` to read in the order they typed it.
  local sql = "SELECT headline_id, tag FROM tags WHERE headline_id IN ("
    .. table.concat(placeholders, ",")
    .. ") ORDER BY rowid"
  local stmt = assert(h:prepare(sql))
  for i, p in ipairs(params) do
    stmt:bind_text(i, p)
  end

  local db = require("organ.db")
  while stmt:step() == db.SQLITE_ROW do
    local id, tag = stmt:column_text(0), stmt:column_text(1)
    local r = id_to_row[id]
    if r then
      r.tags[#r.tags + 1] = tag
    end
  end
  stmt:finalize()
end

-- Augment r.tags with the union of (a) direct tags, (b) tags inherited
-- from each ancestor headline via parent_id, and (c) #+FILETAGS for the
-- containing file. Mirrors `org-tags-inherit` semantics. Idempotent and
-- order-preserving (direct tags come first, then ancestors deepest →
-- shallowest, then filetags).
local function hydrate_inherited_tags(h, rows)
  if #rows == 0 then
    return
  end
  local db = require("organ.db")

  -- Collect every ancestor id we'll need.
  local needed = {}
  for _, r in ipairs(rows) do
    local pid = r.parent_id
    while pid and pid ~= "" do
      needed[pid] = true
      pid = nil -- resolved below
    end
  end

  -- Walk the parent chain in SQL: gather a mapping ancestor_id → tags{}.
  -- This is a single recursive CTE per row to keep latency bounded.
  local id_to_chain = {} -- headline_id → { ancestor_id_1, ..., file_path }
  local chain_sql = [[
    WITH RECURSIVE chain(id, parent_id, file_path, depth) AS (
      SELECT id, parent_id, file_path, 0 FROM headlines WHERE id = ?
      UNION ALL
      SELECT h.id, h.parent_id, h.file_path, c.depth + 1
        FROM headlines h JOIN chain c ON h.id = c.parent_id
    )
    SELECT id, file_path FROM chain ORDER BY depth
  ]]
  local stmt = assert(h:prepare(chain_sql))
  for _, r in ipairs(rows) do
    stmt:reset()
    stmt:bind_text(1, r.id)
    local chain = {}
    local file_path = r.file_path
    while stmt:step() == db.SQLITE_ROW do
      chain[#chain + 1] = stmt:column_text(0)
      file_path = stmt:column_text(1)
    end
    id_to_chain[r.id] = { chain = chain, file_path = file_path }
  end
  stmt:finalize()

  -- Tag lookup for any headline encountered during chain traversal.
  local tag_cache = {}
  local id_set = {}
  for _, info in pairs(id_to_chain) do
    for _, hid in ipairs(info.chain) do
      id_set[hid] = true
    end
  end
  local id_list = {}
  for hid in pairs(id_set) do
    id_list[#id_list + 1] = hid
  end
  if #id_list > 0 then
    local placeholders = {}
    for i = 1, #id_list do
      placeholders[i] = "?"
    end
    local sql = "SELECT headline_id, tag FROM tags WHERE headline_id IN ("
      .. table.concat(placeholders, ",")
      .. ")"
    local s2 = assert(h:prepare(sql))
    for i, hid in ipairs(id_list) do
      s2:bind_text(i, hid)
    end
    while s2:step() == db.SQLITE_ROW do
      local hid = s2:column_text(0)
      tag_cache[hid] = tag_cache[hid] or {}
      tag_cache[hid][#tag_cache[hid] + 1] = s2:column_text(1)
    end
    s2:finalize()
  end

  -- Filetags lookup.
  local file_paths = {}
  for _, info in pairs(id_to_chain) do
    if info.file_path then
      file_paths[info.file_path] = true
    end
  end
  local file_tag_cache = {}
  local fp_list = {}
  for fp in pairs(file_paths) do
    fp_list[#fp_list + 1] = fp
  end
  if #fp_list > 0 then
    local placeholders = {}
    for i = 1, #fp_list do
      placeholders[i] = "?"
    end
    local sql = "SELECT file_path, tag FROM file_tags WHERE file_path IN ("
      .. table.concat(placeholders, ",")
      .. ")"
    local s3 = assert(h:prepare(sql))
    for i, fp in ipairs(fp_list) do
      s3:bind_text(i, fp)
    end
    while s3:step() == db.SQLITE_ROW do
      local fp = s3:column_text(0)
      file_tag_cache[fp] = file_tag_cache[fp] or {}
      file_tag_cache[fp][#file_tag_cache[fp] + 1] = s3:column_text(1)
    end
    s3:finalize()
  end

  -- Tags excluded from inheritance (Emacs `org-tags-exclude-from-
  -- inheritance`).  These appear when set DIRECTLY on a headline /
  -- filetags but never propagate down — useful for marking project
  -- roots (`:project:`), encrypted entries (`:crypt:`), etc.
  local exclude_set = {}
  do
    local ok, organ = pcall(require, "organ")
    if
      ok
      and organ.config
      and require("organ.buf_config").read(nil, "tags")
      and require("organ.buf_config").read(nil, "tags.exclude_from_inheritance")
    then
      for _, t in ipairs(require("organ.buf_config").read(nil, "tags.exclude_from_inheritance")) do
        exclude_set[t] = true
      end
    end
  end

  -- Assemble: direct tags + ancestors (deepest → shallowest) + filetags.
  -- Record `n_direct` so consumers can render the inheritance marker
  -- (Emacs's `::` between inherited and direct tags).
  for _, r in ipairs(rows) do
    local seen = {}
    local out = {}
    for _, t in ipairs(r.tags or {}) do
      if not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
    end
    local n_direct = #out
    local info = id_to_chain[r.id]
    if info then
      -- chain[1] is r itself; ancestors start at chain[2].
      for i = 2, #info.chain do
        local atags = tag_cache[info.chain[i]] or {}
        for _, t in ipairs(atags) do
          if not seen[t] and not exclude_set[t] then
            seen[t] = true
            out[#out + 1] = t
          end
        end
      end
      local ftags = info.file_path and file_tag_cache[info.file_path] or {}
      for _, t in ipairs(ftags) do
        if not seen[t] and not exclude_set[t] then
          seen[t] = true
          out[#out + 1] = t
        end
      end
    end
    r.tags = out
    r.n_direct_tags = n_direct
    r.inherited_tags_resolved = true
  end
end

local function hydrate_properties(h, rows)
  if #rows == 0 then
    return
  end
  local id_to_row = {}
  local placeholders, params = {}, {}
  for i, r in ipairs(rows) do
    id_to_row[r.id] = r
    placeholders[i] = "?"
    params[i] = r.id
    r.properties = {}
  end

  local sql = "SELECT headline_id, key, value FROM properties WHERE headline_id IN ("
    .. table.concat(placeholders, ",")
    .. ")"
  local stmt = assert(h:prepare(sql))
  for i, p in ipairs(params) do
    stmt:bind_text(i, p)
  end

  local db = require("organ.db")
  while stmt:step() == db.SQLITE_ROW do
    local id, key, val = stmt:column_text(0), stmt:column_text(1), stmt:column_text(2)
    local r = id_to_row[id]
    if r then
      r.properties[key] = val
    end
  end
  stmt:finalize()
end

-- Hydrate backlink_count: for each headline row whose `id` is NOT a
-- synthetic line-address (i.e. not "%#L%"), count inbound id-type links.
local function hydrate_backlink_counts(h, rows)
  if #rows == 0 then
    return
  end
  local id_to_row = {}
  local real_ids = {} -- only real org IDs have backlinks worth counting
  for _, r in ipairs(rows) do
    r.backlink_count = 0
    if not r.id:find("#L", 1, true) then
      id_to_row[r.id] = r
      real_ids[#real_ids + 1] = r.id
    end
  end
  if #real_ids == 0 then
    return
  end

  local placeholders = {}
  for i = 1, #real_ids do
    placeholders[i] = "?"
  end
  local sql = "SELECT target, COUNT(*) FROM links WHERE target_type = 'id' AND target IN ("
    .. table.concat(placeholders, ",")
    .. ") GROUP BY target"
  local stmt = assert(h:prepare(sql))
  for i, id in ipairs(real_ids) do
    stmt:bind_text(i, id)
  end

  local db = require("organ.db")
  while stmt:step() == db.SQLITE_ROW do
    local id = stmt:column_text(0)
    local cnt = stmt:column_int(1)
    local r = id_to_row[id]
    if r then
      r.backlink_count = cnt
    end
  end
  stmt:finalize()
end

function M.headlines(filters)
  filters = filters or {}
  local h = (filters and filters.db) or default_db()
  local sql, params = M._build_sql(filters)
  local rows = rows_from_select(h, sql, params)
  hydrate_tags(h, rows)
  if filters.include_inherited_tags then
    hydrate_inherited_tags(h, rows)
  end
  if filters.include_properties then
    hydrate_properties(h, rows)
  end
  if filters.include_backlink_counts then
    hydrate_backlink_counts(h, rows)
  end
  return rows
end

-- agenda: common-case scheduled + deadline window across a date range.
-- opts = { from, to, types, todo, tags, priority, limit, include_properties }
-- `types` controls which date fields the window applies to.
function M.agenda(opts)
  opts = opts or {}
  local types = opts.types or { "scheduled", "deadline" }

  local default_order = opts.order_by
    or {
      { "COALESCE(scheduled_date, deadline_date)", "asc" },
      { "priority", "asc" },
      { "todo_state", "asc" },
      { "title", "asc" },
    }

  -- agenda semantics: ANY of the type windows matches, not ALL. The builder
  -- AND's multiple date windows, so we pass just one if `types` is singleton,
  -- or call headlines multiple times and merge+dedupe by id when >1.
  if #types == 1 then
    local filters = {
      todo = opts.todo,
      tags = opts.tags,
      priority = opts.priority,
      title_match = opts.title_match,
      limit = opts.limit,
      include_properties = opts.include_properties,
      include_inherited_tags = opts.include_inherited_tags,
      files = opts.files,
      order_by = default_order,
    }
    if types[1] == "scheduled" then
      filters.scheduled = { from = opts.from, to = opts.to }
    elseif types[1] == "deadline" then
      filters.deadline = { from = opts.from, to = opts.to }
    elseif types[1] == "closed" then
      filters.closed = { from = opts.from, to = opts.to }
    end
    return M.headlines(filters)
  end

  local seen, merged = {}, {}
  for _, t in ipairs(types) do
    local per = {
      todo = opts.todo,
      tags = opts.tags,
      priority = opts.priority,
      title_match = opts.title_match,
      limit = opts.limit,
      include_properties = opts.include_properties,
      include_inherited_tags = opts.include_inherited_tags,
      files = opts.files,
      order_by = default_order,
    }
    if t == "scheduled" then
      per.scheduled = { from = opts.from, to = opts.to }
    elseif t == "deadline" then
      per.deadline = { from = opts.from, to = opts.to }
    elseif t == "closed" then
      per.closed = { from = opts.from, to = opts.to }
    end
    for _, r in ipairs(M.headlines(per)) do
      if not seen[r.id] then
        seen[r.id] = true
        merged[#merged + 1] = r
      end
    end
  end
  return merged
end

function M.by_tag(tags, opts)
  opts = opts or {}
  local filters = {
    tags = { any = tags },
    todo = opts.todo,
    priority = opts.priority,
    limit = opts.limit,
    order_by = opts.order_by or { { "title", "asc" } },
    include_properties = opts.include_properties,
  }
  return M.headlines(filters)
end

function M.by_todo(states, opts)
  opts = opts or {}
  return M.headlines({
    todo = states,
    tags = opts.tags,
    priority = opts.priority,
    limit = opts.limit,
    order_by = opts.order_by or { { "priority", "asc" }, { "title", "asc" } },
    include_properties = opts.include_properties,
  })
end

function M.by_file(path, opts)
  opts = opts or {}
  return M.headlines({
    file = path,
    todo = opts.todo,
    tags = opts.tags,
    limit = opts.limit,
    order_by = opts.order_by or { { "line_start", "asc" } },
    include_properties = opts.include_properties,
  })
end

-- Links / roam API.

function M.get_by_id(id, opts)
  opts = opts or {}
  local h = opts.db or default_db()
  local stmt = assert(
    h:prepare(
      "SELECT id, file_path, parent_id, level, title, todo_state, priority, "
        .. "scheduled, deadline, closed, scheduled_date, deadline_date, closed_date, "
        .. "line_start, line_end, commented FROM headlines WHERE id = ?"
    )
  )
  stmt:bind_text(1, id)
  local db = require("organ.db")
  local rc = stmt:step()
  if rc ~= db.SQLITE_ROW then
    stmt:finalize()
    return nil
  end
  local rec = {
    id = stmt:column_text(0),
    file_path = stmt:column_text(1),
    parent_id = stmt:column_text(2),
    level = stmt:column_int(3),
    title = stmt:column_text(4),
    todo_state = stmt:column_text(5),
    priority = stmt:column_text(6),
    scheduled = stmt:column_text(7),
    deadline = stmt:column_text(8),
    closed = stmt:column_text(9),
    scheduled_date = stmt:column_text(10),
    deadline_date = stmt:column_text(11),
    closed_date = stmt:column_text(12),
    line_start = stmt:column_int(13),
    line_end = stmt:column_int(14),
    commented = stmt:column_int(15) == 1,
    tags = {},
  }
  stmt:finalize()
  return rec
end

function M.links_from(headline_id, opts)
  opts = opts or {}
  local h = opts.db or default_db()
  local stmt = assert(h:prepare([[
    SELECT l.target_type, l.target, l.description, l.line,
           h.id, h.file_path, h.title, h.line_start,
           h.todo_state, h.priority
      FROM links l
      LEFT JOIN headlines h
        ON l.target_type = 'id' AND l.target = h.id
     WHERE l.source_headline_id = ?
     ORDER BY l.line
  ]]))
  stmt:bind_text(1, headline_id)
  local db = require("organ.db")
  local rows = {}
  while stmt:step() == db.SQLITE_ROW do
    local target_headline
    local th_id = stmt:column_text(4)
    if th_id and th_id ~= "" then
      target_headline = {
        id = th_id,
        file_path = stmt:column_text(5),
        title = stmt:column_text(6),
        line_start = stmt:column_int(7),
        todo_state = stmt:column_text(8),
        priority = stmt:column_text(9),
      }
    end
    rows[#rows + 1] = {
      target_type = stmt:column_text(0),
      target = stmt:column_text(1),
      description = stmt:column_text(2),
      line = stmt:column_int(3),
      target_headline = target_headline,
    }
  end
  stmt:finalize()
  return rows
end

function M.links_to(target, opts)
  opts = opts or {}
  local h = opts.db or default_db()
  local id
  if type(target) == "string" then
    id = target
  elseif type(target) == "table" and target.id then
    id = target.id
  else
    error("query.links_to: target must be id string or headline record")
  end
  local stmt = assert(h:prepare([[
    SELECT l.description, l.line, l.target_type, l.target,
           h.id, h.file_path, h.title, h.line_start,
           h.todo_state, h.priority
      FROM links l
      INNER JOIN headlines h ON h.id = l.source_headline_id
     WHERE l.target_type = 'id' AND l.target = ?
     ORDER BY h.file_path, h.line_start
  ]]))
  stmt:bind_text(1, id)
  local db = require("organ.db")
  local rows = {}
  while stmt:step() == db.SQLITE_ROW do
    rows[#rows + 1] = {
      description = stmt:column_text(0),
      line = stmt:column_int(1),
      target_type = stmt:column_text(2),
      target = stmt:column_text(3),
      source_headline = {
        id = stmt:column_text(4),
        file_path = stmt:column_text(5),
        title = stmt:column_text(6),
        line_start = stmt:column_int(7),
        todo_state = stmt:column_text(8),
        priority = stmt:column_text(9),
      },
    }
  end
  stmt:finalize()
  return rows
end

-- Title-based references: every `[[*Title]]` link whose target matches
-- `title` (exact-string, case-sensitive — Emacs's default behavior).
-- Returned shape mirrors `M.links_to` so callers can union the two.
function M.title_refs(title, opts)
  opts = opts or {}
  if type(title) ~= "string" or title == "" then
    return {}
  end
  local h = opts.db or default_db()
  local stmt = assert(h:prepare([[
    SELECT l.description, l.line, l.target_type, l.target,
           h.id, h.file_path, h.title, h.line_start,
           h.todo_state, h.priority
      FROM links l
      INNER JOIN headlines h ON h.id = l.source_headline_id
     WHERE l.target_type = 'headline' AND l.target = ?
     ORDER BY h.file_path, h.line_start
  ]]))
  stmt:bind_text(1, title)
  local db = require("organ.db")
  local rows = {}
  while stmt:step() == db.SQLITE_ROW do
    rows[#rows + 1] = {
      description = stmt:column_text(0),
      line = stmt:column_int(1),
      target_type = stmt:column_text(2),
      target = stmt:column_text(3),
      source_headline = {
        id = stmt:column_text(4),
        file_path = stmt:column_text(5),
        title = stmt:column_text(6),
        line_start = stmt:column_int(7),
        todo_state = stmt:column_text(8),
        priority = stmt:column_text(9),
      },
    }
  end
  stmt:finalize()
  return rows
end

function M.resolve(target_text)
  return require("organ.link").resolve(target_text)
end

function M.links(filter, opts)
  filter = filter or {}
  opts = opts or {}
  local h = opts.db or default_db()

  local where, params = {}, {}
  if filter.target_type then
    local types = vim.split(filter.target_type, ",", { trimempty = true })
    local placeholders = {}
    for _, t in ipairs(types) do
      placeholders[#placeholders + 1] = "?"
      params[#params + 1] = t
    end
    where[#where + 1] = "l.target_type IN (" .. table.concat(placeholders, ",") .. ")"
  end
  if filter.source_id then
    where[#where + 1] = "l.source_headline_id = ?"
    params[#params + 1] = filter.source_id
  end
  if filter.target then
    where[#where + 1] = "l.target = ?"
    params[#params + 1] = filter.target
  end

  local where_sql = (#where > 0) and ("\nWHERE " .. table.concat(where, " AND ")) or ""

  local sql = [[
    SELECT
      l.source_headline_id,
      l.target_type,
      l.target,
      l.description,
      l.line,
      sh.title      AS source_title,
      sh.file_path  AS source_file,
      sh.line_start AS source_line_start,
      th.id         AS target_headline_id,
      th.title      AS target_headline_title,
      th.file_path  AS target_headline_file,
      th.line_start AS target_headline_line_start
    FROM links l
    INNER JOIN headlines sh ON sh.id = l.source_headline_id
    LEFT  JOIN headlines th ON l.target_type = 'id' AND l.target = th.id
  ]] .. where_sql .. "\nORDER BY sh.file_path, sh.line_start, l.line"

  local rows = {}
  local stmt = assert(h:prepare(sql))
  for i, p in ipairs(params) do
    stmt:bind_text(i, p)
  end
  local db = require("organ.db")
  while stmt:step() == db.SQLITE_ROW do
    local target_headline
    local thid = stmt:column_text(8)
    if thid and thid ~= "" then
      target_headline = {
        id = thid,
        title = stmt:column_text(9),
        file_path = stmt:column_text(10),
        line_start = stmt:column_int(11),
      }
    end
    rows[#rows + 1] = {
      source_headline_id = stmt:column_text(0),
      target_type = stmt:column_text(1),
      target = stmt:column_text(2),
      description = stmt:column_text(3),
      line = stmt:column_int(4),
      source_headline = {
        id = stmt:column_text(0),
        title = stmt:column_text(5),
        file_path = stmt:column_text(6),
        line_start = stmt:column_int(7),
      },
      target_headline = target_headline,
    }
  end
  stmt:finalize()
  return rows
end

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

  local projects = M.headlines(effective_filter)
  if #projects == 0 then
    return {}
  end

  local h = default_db()

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
  local s = assert(h:prepare(sql))
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
  local h = opts.db or default_db()
  local sql = [[
    SELECT f.path AS file_path, COUNT(hl.id) AS headline_count, f.indexed AS last_indexed
      FROM files f
      LEFT JOIN headlines hl ON hl.file_path = f.path
     GROUP BY f.path
     ORDER BY f.path
  ]]
  local s = assert(h:prepare(sql))
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
  local h = opts.db or default_db()
  -- Build a parameterised IN list (one `?` per path).
  local placeholders = {}
  for i = 1, #file_paths do
    placeholders[i] = "?"
  end
  local sql = "SELECT file_path, keyword, is_done FROM file_todo_keywords"
    .. " WHERE file_path IN ("
    .. table.concat(placeholders, ",")
    .. ")"
  local s = assert(h:prepare(sql))
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
--     map { headline_id → list of dates }
function M.habit_completions(opts)
  opts = opts or {}
  local h = opts.db or default_db()
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
  local h = opts.db or default_db()
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
  local s = assert(h:prepare(sql))
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
    local r = M.get_by_id(id, { db = h })
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
  local h = default_db()
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

  local stmt = assert(h:prepare(sql))
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
  local h = default_db()
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

  local stmt = assert(h:prepare(sql))
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
