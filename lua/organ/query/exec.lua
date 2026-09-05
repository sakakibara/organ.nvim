-- Runs built SQL against the index DB and hydrates result rows
-- (tags, inherited tags, properties, backlink counts).

local M = {}

-- SQLITE_MAX_VARIABLE_NUMBER is 999 on builds predating SQLite 3.32, so
-- an `IN (...)` list with one placeholder per result row has to be split.
-- Overridable so tests can drive the split path with a handful of rows.
M._bind_chunk = 500

local function chunked(list)
  local size = M._bind_chunk
  local out = {}
  for i = 1, #list, size do
    local part = {}
    for j = i, math.min(i + size - 1, #list) do
      part[#part + 1] = list[j]
    end
    out[#out + 1] = part
  end
  return out
end

local function placeholders_for(list)
  local q = {}
  for i = 1, #list do
    q[i] = "?"
  end
  return table.concat(q, ",")
end

-- Execution helpers.

local function default_db()
  return require("organ.runtime").db()
end

-- The DB handle for a query: the caller's `opts.db` if given, else the
-- shared runtime handle. `opts` may be nil.
local function resolve_db(opts)
  return (opts and opts.db) or default_db()
end

-- Prepare a statement, raising a contextual error blamed at the caller if
-- the handle rejects the SQL.  A hardcoded query that fails to prepare is a
-- bug (bad SQL or a closed handle), not a recoverable condition.
local function prepare(h, sql)
  local stmt, err = h:prepare(sql)
  if not stmt then
    error("organ.query: prepare failed: " .. tostring(err), 2)
  end
  return stmt
end

local function rows_from_select(h, sql, params)
  local stmt = prepare(h, sql)
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
  local ids = {}
  for i, r in ipairs(rows) do
    id_to_row[r.id] = r
    ids[i] = r.id
  end

  local db = require("organ.db")
  for _, part in ipairs(chunked(ids)) do
    -- ORDER BY rowid so tags come back in insertion (= file-source) order.
    -- Without this, SQLite's PRIMARY KEY (headline_id, tag) index returns
    -- tags alphabetically, which breaks Emacs-style display where users
    -- expect `:gtd:@phone:` to read in the order they typed it.
    local sql = "SELECT headline_id, tag FROM tags WHERE headline_id IN ("
      .. placeholders_for(part)
      .. ") ORDER BY rowid"
    local stmt = prepare(h, sql)
    for i, p in ipairs(part) do
      stmt:bind_text(i, p)
    end
    while stmt:step() == db.SQLITE_ROW do
      local id, tag = stmt:column_text(0), stmt:column_text(1)
      local r = id_to_row[id]
      if r then
        r.tags[#r.tags + 1] = tag
      end
    end
    stmt:finalize()
  end
end

-- Augment r.tags with the union of (a) direct tags, (b) tags inherited
-- from each ancestor headline via parent_id, and (c) #+FILETAGS for the
-- containing file. Mirrors `org-tags-inherit` semantics. Idempotent and
-- order-preserving (direct tags come first, then ancestors deepest ->
-- shallowest, then filetags).
local function hydrate_inherited_tags(h, rows)
  if #rows == 0 then
    return
  end
  local db = require("organ.db")

  -- Walk the parent chain in SQL: gather a mapping ancestor_id -> tags{}.
  -- This is a single recursive CTE per row to keep latency bounded.
  local id_to_chain = {} -- headline_id -> { ancestor_id_1, ..., file_path }
  local chain_sql = [[
    WITH RECURSIVE chain(id, parent_id, file_path, depth) AS (
      SELECT id, parent_id, file_path, 0 FROM headlines WHERE id = ?
      UNION ALL
      SELECT h.id, h.parent_id, h.file_path, c.depth + 1
        FROM headlines h JOIN chain c ON h.id = c.parent_id
    )
    SELECT id, file_path FROM chain ORDER BY depth
  ]]
  local stmt = prepare(h, chain_sql)
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
  for _, part in ipairs(chunked(id_list)) do
    local sql = "SELECT headline_id, tag FROM tags WHERE headline_id IN ("
      .. placeholders_for(part)
      .. ")"
    local s2 = prepare(h, sql)
    for i, hid in ipairs(part) do
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
  for _, part in ipairs(chunked(fp_list)) do
    local sql = "SELECT file_path, tag FROM file_tags WHERE file_path IN ("
      .. placeholders_for(part)
      .. ")"
    local s3 = prepare(h, sql)
    for i, fp in ipairs(part) do
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
  -- filetags but never propagate down -- useful for marking project
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

  -- Assemble: direct tags + ancestors (deepest -> shallowest) + filetags.
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
  local ids = {}
  for i, r in ipairs(rows) do
    id_to_row[r.id] = r
    ids[i] = r.id
    r.properties = {}
  end

  local db = require("organ.db")
  for _, part in ipairs(chunked(ids)) do
    local sql = "SELECT headline_id, key, value FROM properties WHERE headline_id IN ("
      .. placeholders_for(part)
      .. ")"
    local stmt = prepare(h, sql)
    for i, p in ipairs(part) do
      stmt:bind_text(i, p)
    end
    while stmt:step() == db.SQLITE_ROW do
      local id, key, val = stmt:column_text(0), stmt:column_text(1), stmt:column_text(2)
      local r = id_to_row[id]
      if r then
        r.properties[key] = val
      end
    end
    stmt:finalize()
  end
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

  local db = require("organ.db")
  for _, part in ipairs(chunked(real_ids)) do
    local sql = "SELECT target, COUNT(*) FROM links WHERE target_type = 'id' AND target IN ("
      .. placeholders_for(part)
      .. ") GROUP BY target"
    local stmt = prepare(h, sql)
    for i, id in ipairs(part) do
      stmt:bind_text(i, id)
    end
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
end

M.chunked = chunked
M.placeholders_for = placeholders_for
M.default_db = default_db
M.resolve_db = resolve_db
M.prepare = prepare
M.rows_from_select = rows_from_select
M.hydrate_tags = hydrate_tags
M.hydrate_inherited_tags = hydrate_inherited_tags
M.hydrate_properties = hydrate_properties
M.hydrate_backlink_counts = hydrate_backlink_counts

return M
