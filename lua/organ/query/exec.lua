-- Runs built SQL against the index DB and hydrates result rows
-- (tags, inherited tags, properties, backlink counts).

local M = {}

-- Execution helpers.

local function default_db()
  return require("organ.runtime").db()
end

-- The DB handle for a query: the caller's `opts.db` if given, else the
-- shared runtime handle. `opts` may be nil.
local function resolve_db(opts)
  return (opts and opts.db) or default_db()
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
-- order-preserving (direct tags come first, then ancestors deepest ->
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

M.default_db = default_db
M.resolve_db = resolve_db
M.rows_from_select = rows_from_select
M.hydrate_tags = hydrate_tags
M.hydrate_inherited_tags = hydrate_inherited_tags
M.hydrate_properties = hydrate_properties
M.hydrate_backlink_counts = hydrate_backlink_counts

return M
