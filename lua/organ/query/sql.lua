-- SQL builder. Turns a filter table into a (sql, params) pair. Emits a
-- parameterised SELECT against the `headlines` table; joins/subqueries
-- are added only for filters that need them. All values pass through
-- prepared-statement bindings -- never string-interpolated into SQL.

local M = {}
local dates = require("organ.query.dates")

local BASE_COLUMNS = {
  "h.id",
  "h.file_path",
  "h.parent_id",
  "h.level",
  "h.title",
  "h.todo_state",
  "h.priority",
  "h.scheduled",
  "h.deadline",
  "h.closed",
  "h.scheduled_date",
  "h.deadline_date",
  "h.closed_date",
  "h.line_start",
  "h.line_end",
  "h.commented",
}

local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  if next(t) == nil then
    return true
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n == #t
end

local function date_range_clause(col, window, where, params)
  if window == nil then
    return
  end
  if window.from ~= nil then
    local iso = dates.parse_date(window.from)
    if iso then
      where[#where + 1] = string.format("%s >= ?", col)
      params[#params + 1] = iso
    end
  end
  if window.to ~= nil then
    local iso = dates.parse_date(window.to)
    if iso then
      -- Date-only upper bound: extend to end-of-day so timestamps
      -- with HH:MM (e.g. "2026-05-04T10:00") still satisfy the
      -- `<= "2026-05-04"` comparison that lexical ordering would
      -- otherwise reject.  ISO timestamps stored in the index use
      -- the literal `T` separator, making the comparison stable.
      if iso:match("^%d%d%d%d%-%d%d%-%d%d$") then
        iso = iso .. "T23:59"
      end
      where[#where + 1] = string.format("%s <= ?", col)
      params[#params + 1] = iso
    end
  end
end

local function todo_clause(filter, where, params)
  if filter == nil then
    return
  end

  local include, exclude
  if is_array(filter) then
    include = filter
  else
    include, exclude = filter.include, filter.exclude
  end

  if include and #include > 0 then
    local q = {}
    for _ = 1, #include do
      q[#q + 1] = "?"
    end
    where[#where + 1] = "todo_state IN (" .. table.concat(q, ",") .. ")"
    for _, s in ipairs(include) do
      params[#params + 1] = s
    end
  end
  if exclude and #exclude > 0 then
    local q = {}
    for _ = 1, #exclude do
      q[#q + 1] = "?"
    end
    where[#where + 1] = "(todo_state IS NULL OR todo_state NOT IN (" .. table.concat(q, ",") .. "))"
    for _, s in ipairs(exclude) do
      params[#params + 1] = s
    end
  end
end

-- Recursive CTE prefix for tag inheritance.  Emitted when inherit = true.
-- ancestors: walk parent_id chain upward from each headline.
-- effective_tags: union of all ancestor tags + all file-level tags.
local CTE_TAGS_INHERIT = [[WITH RECURSIVE
ancestors(headline_id, anc_id) AS (
  SELECT id, id FROM headlines
  UNION ALL
  SELECT a.headline_id, h.parent_id
    FROM ancestors a JOIN headlines h ON h.id = a.anc_id
   WHERE h.parent_id IS NOT NULL
),
effective_tags(headline_id, tag) AS (
  SELECT a.headline_id, t.tag
    FROM ancestors a JOIN tags t ON t.headline_id = a.anc_id
  UNION
  SELECT h.id, ft.tag
    FROM headlines h JOIN file_tags ft ON ft.file_path = h.file_path
)
]]

-- Returns (cte_prefix, joins_sql, extra_where_sql, params).
-- cte_prefix is non-empty only when there is a tag filter AND inherit=true.
local function tag_joins(filter)
  if filter == nil then
    return "", "", "", {}
  end

  local any_, all_, none_
  if is_array(filter) then
    any_ = filter
  else
    any_ = filter.any
    all_ = filter.all
    none_ = filter.none
  end

  if not any_ and not all_ and not none_ then
    return "", "", "", {}
  end

  -- Resolve inherit: per-filter wins, else config default, else true.
  local inherit
  if filter.inherit ~= nil then
    inherit = filter.inherit
  else
    local ok, organ = pcall(require, "organ")
    if
      ok
      and organ.config
      and require("organ.buf_config").read(nil, "tags")
      and require("organ.buf_config").read(nil, "tags.inherit") ~= nil
    then
      inherit = require("organ.buf_config").read(nil, "tags.inherit")
    else
      inherit = true
    end
  end

  local tbl = inherit and "effective_tags" or "tags"
  local cte = inherit and CTE_TAGS_INHERIT or ""

  local joins, where, params = {}, {}, {}

  if all_ and #all_ > 0 then
    local q = {}
    for _ = 1, #all_ do
      q[#q + 1] = "?"
    end
    joins[#joins + 1] = string.format(
      [[
      INNER JOIN (
        SELECT headline_id FROM %s
        WHERE tag IN (%s)
        GROUP BY headline_id
        HAVING COUNT(DISTINCT tag) = ?
      ) AS tags_all ON tags_all.headline_id = h.id
    ]],
      tbl,
      table.concat(q, ",")
    )
    for _, t in ipairs(all_) do
      params[#params + 1] = t
    end
    params[#params + 1] = #all_
  end

  if any_ and #any_ > 0 then
    local q = {}
    for _ = 1, #any_ do
      q[#q + 1] = "?"
    end
    joins[#joins + 1] = string.format(
      [[
      INNER JOIN (
        SELECT DISTINCT headline_id FROM %s WHERE tag IN (%s)
      ) AS tags_any ON tags_any.headline_id = h.id
    ]],
      tbl,
      table.concat(q, ",")
    )
    for _, t in ipairs(any_) do
      params[#params + 1] = t
    end
  end

  if none_ and #none_ > 0 then
    local q = {}
    for _ = 1, #none_ do
      q[#q + 1] = "?"
    end
    joins[#joins + 1] = string.format(
      [[
      LEFT JOIN %s AS tags_none
        ON tags_none.headline_id = h.id AND tags_none.tag IN (%s)
    ]],
      tbl,
      table.concat(q, ",")
    )
    for _, t in ipairs(none_) do
      params[#params + 1] = t
    end
    where[#where + 1] = "tags_none.tag IS NULL"
  end

  return cte, table.concat(joins, "\n"), table.concat(where, " AND "), params
end

local function priority_clause(filter, where, params)
  if filter == nil then
    return
  end
  if #filter == 0 then
    return
  end
  local q = {}
  for _ = 1, #filter do
    q[#q + 1] = "?"
  end
  where[#where + 1] = "priority IN (" .. table.concat(q, ",") .. ")"
  for _, p in ipairs(filter) do
    params[#params + 1] = p
  end
end

local function level_clause(filter, where, params)
  if filter == nil then
    return
  end
  if type(filter) == "number" then
    where[#where + 1] = "level = ?"
    params[#params + 1] = filter
    return
  end
  if filter.min ~= nil then
    where[#where + 1] = "level >= ?"
    params[#params + 1] = filter.min
  end
  if filter.max ~= nil then
    where[#where + 1] = "level <= ?"
    params[#params + 1] = filter.max
  end
end

local function file_clauses(filters, where, params)
  if filters.file then
    local canon = require("organ.path").canonical(filters.file)
    where[#where + 1] = "file_path = ?"
    params[#params + 1] = canon or filters.file
  end
  if filters.file_glob then
    where[#where + 1] = "file_path GLOB ?"
    params[#params + 1] = filters.file_glob
  end
  -- `files` is a list of canonical paths the result must come from
  -- (the agenda-files filter that mirrors Emacs's `org-agenda-files`).
  -- An empty list means "no rows match" -- keep that semantically
  -- distinct from nil (which means "no file restriction").
  if filters.files ~= nil then
    if #filters.files == 0 then
      where[#where + 1] = "0 = 1" -- guaranteed-empty result set
    else
      local placeholders = {}
      for _, p in ipairs(filters.files) do
        placeholders[#placeholders + 1] = "?"
        params[#params + 1] = require("organ.path").canonical(p) or p
      end
      where[#where + 1] = "file_path IN (" .. table.concat(placeholders, ",") .. ")"
    end
  end
end

local function title_clause(filters, where, params)
  if filters.title_match == nil or filters.title_match == "" then
    return
  end
  local match_aliases = filters.match_aliases
  if match_aliases == nil then
    match_aliases = true
  end
  if match_aliases then
    where[#where + 1] =
      "(h.title LIKE ? OR EXISTS (SELECT 1 FROM aliases a WHERE a.headline_id = h.id AND a.alias LIKE ?))"
    params[#params + 1] = "%" .. filters.title_match .. "%"
    params[#params + 1] = "%" .. filters.title_match .. "%"
  else
    where[#where + 1] = "h.title LIKE ?"
    params[#params + 1] = "%" .. filters.title_match .. "%"
  end
end

local function parent_clause(filters, where, params)
  if filters.has_parent == true then
    where[#where + 1] = "parent_id IS NOT NULL"
  elseif filters.has_parent == false then
    where[#where + 1] = "parent_id IS NULL"
  end

  if filters.parent_id ~= nil then
    if filters.recursive then
      where[#where + 1] = "__RECURSIVE_PARENT__"
      params[#params + 1] = filters.parent_id
    else
      where[#where + 1] = "parent_id = ?"
      params[#params + 1] = filters.parent_id
    end
  end
end

local function has_id_clause(filters, where, params)
  if filters.has_id == true then
    where[#where + 1] = "h.id NOT LIKE ?"
    params[#params + 1] = "%#L%"
  elseif filters.has_id == false then
    where[#where + 1] = "h.id LIKE ?"
    params[#params + 1] = "%#L%"
  end
end

-- Returns (join_sql, where_sql, params) for the has_property filter.
-- When no has_property filter is set, returns ("", "", {}).
local function has_property_join(filters)
  if filters.has_property == nil then
    return "", "", {}
  end
  return "JOIN properties prop ON prop.headline_id = h.id\n",
    "prop.key = ?",
    { filters.has_property }
end

local function order_limit(filters)
  local parts = {}
  local order_params = {}

  if filters.order_by then
    local cols = {}
    for _, spec in ipairs(filters.order_by) do
      local col, dir = spec[1], (spec[2] or "asc"):upper()
      if dir ~= "ASC" and dir ~= "DESC" then
        dir = "ASC"
      end
      -- Accept plain column names or whitelisted expressions (alphanumerics,
      -- underscore, commas, parentheses, spaces). Any other character bails.
      if not col:match("^[%w_ ,()]+$") then
        error("invalid order_by column: " .. col)
      end
      cols[#cols + 1] = col .. " " .. dir
    end
    if #cols > 0 then
      parts[#parts + 1] = "ORDER BY " .. table.concat(cols, ", ")
    end
  end

  if filters.limit then
    parts[#parts + 1] = "LIMIT ?"
    order_params[#order_params + 1] = filters.limit
  end
  if filters.offset then
    parts[#parts + 1] = "OFFSET ?"
    order_params[#order_params + 1] = filters.offset
  end

  return table.concat(parts, " "), order_params
end

function M.build(filters)
  filters = filters or {}

  local params = {}
  local where = {}

  date_range_clause("scheduled_date", filters.scheduled, where, params)
  date_range_clause("deadline_date", filters.deadline, where, params)
  date_range_clause("closed_date", filters.closed, where, params)
  todo_clause(filters.todo, where, params)
  priority_clause(filters.priority, where, params)
  level_clause(filters.level, where, params)
  file_clauses(filters, where, params)
  title_clause(filters, where, params)
  parent_clause(filters, where, params)
  has_id_clause(filters, where, params)

  local tag_cte, tag_join_sql, tag_where, tag_params = tag_joins(filters.tags)
  for _, p in ipairs(tag_params) do
    params[#params + 1] = p
  end
  if tag_where ~= "" then
    where[#where + 1] = tag_where
  end

  local prop_join_sql, prop_where, prop_params = has_property_join(filters)
  for _, p in ipairs(prop_params) do
    params[#params + 1] = p
  end
  if prop_where ~= "" then
    where[#where + 1] = prop_where
  end

  -- Handle the recursive-parent sentinel by prepending a CTE and replacing
  -- the marker with a subquery reference.
  local parent_cte = ""
  for i, clause in ipairs(where) do
    if clause == "__RECURSIVE_PARENT__" then
      parent_cte = [[
WITH RECURSIVE descendants(id) AS (
  SELECT id FROM headlines WHERE parent_id = ?
  UNION ALL
  SELECT h2.id FROM headlines h2 JOIN descendants d ON h2.parent_id = d.id
)
]]
      where[i] = "h.id IN (SELECT id FROM descendants)"
    end
  end

  -- Merge any CTEs: tag_cte and parent_cte are mutually exclusive in practice,
  -- but if both are needed we combine them by stripping "WITH RECURSIVE" from
  -- the second and joining with a comma.
  local cte
  if tag_cte ~= "" and parent_cte ~= "" then
    -- Strip leading "WITH RECURSIVE\n" from parent_cte and append after tag_cte's CTEs.
    local parent_body = parent_cte:gsub("^WITH RECURSIVE%s*\n", "")
    -- tag_cte ends with "\n]\n" -- insert a comma before the closing newline
    cte = tag_cte:gsub("\n$", ",\n") .. parent_body
  elseif tag_cte ~= "" then
    cte = tag_cte
  else
    cte = parent_cte
  end

  local cols = table.concat(BASE_COLUMNS, ", ")
  local sql = cte .. "SELECT " .. cols .. "\nFROM headlines h\n" .. tag_join_sql .. prop_join_sql

  if #where > 0 then
    sql = sql .. "\nWHERE " .. table.concat(where, " AND ")
  end

  local tail, tail_params = order_limit(filters)
  if tail ~= "" then
    sql = sql .. "\n" .. tail
    for _, p in ipairs(tail_params) do
      params[#params + 1] = p
    end
  end

  return sql, params
end

return M
