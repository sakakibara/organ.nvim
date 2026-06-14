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
local exec = require("organ.query.exec")
local links = require("organ.query.links")
local reports = require("organ.query.reports")
local sql = require("organ.query.sql")

-- organ.query's public surface is assembled from the query submodules.
-- The assert keeps two submodules from silently claiming the same name.
local function merge(src)
  for k, v in pairs(src) do
    assert(M[k] == nil, "organ.query: duplicate member " .. k)
    M[k] = v
  end
end
merge(links)
merge(reports)

M.parse_date = dates.parse_date
-- The SQL builder keeps its historical seam name on the facade:
-- query_builder_test calls _build_sql, and M.headlines dispatches through it.
M._build_sql = sql.build

function M.headlines(filters)
  filters = filters or {}
  local h = exec.resolve_db(filters)
  local sql, params = M._build_sql(filters)
  local rows = exec.rows_from_select(h, sql, params)
  exec.hydrate_tags(h, rows)
  if filters.include_inherited_tags then
    exec.hydrate_inherited_tags(h, rows)
  end
  if filters.include_properties then
    exec.hydrate_properties(h, rows)
  end
  if filters.include_backlink_counts then
    exec.hydrate_backlink_counts(h, rows)
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

return M
