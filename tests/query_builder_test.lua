-- Unit tests for query's internal build_sql.
-- Run via: nvim --headless -l tests/query_builder_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local query = require("organ.query")

-- Normalize whitespace for stable comparison.
local function normal(s)
  return s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function assert_build(filters, expected_sql_frag, expected_param_count)
  local sql, params = query._build_sql(filters)
  sql = normal(sql)
  if not sql:find(expected_sql_frag, 1, true) then
    io.stderr:write("sql:\n" .. sql .. "\n\nmissing fragment:\n" .. expected_sql_frag .. "\n")
    os.exit(1)
  end
  if expected_param_count and #params ~= expected_param_count then
    io.stderr:write(
      string.format(
        "param count: got %d, expected %d; params=%s\n",
        #params,
        expected_param_count,
        vim.inspect(params)
      )
    )
    os.exit(1)
  end
end

-- No filters: SELECT with no WHERE predicates.
do
  local sql, params = query._build_sql({})
  sql = normal(sql)
  assert(sql:find("FROM headlines", 1, true), "base FROM missing")
  assert(not sql:find("WHERE", 1, true), "empty filters should have no WHERE")
  assert(#params == 0)
end

-- scheduled window
assert_build(
  { scheduled = { from = "2026-04-23", to = "2026-04-30" } },
  "scheduled_date >= ? AND scheduled_date <= ?",
  2
)

-- deadline + closed windows (AND'd)
assert_build({
  deadline = { from = "2026-04-23", to = "2026-04-30" },
  closed = { from = "2026-01-01", to = "2026-04-23" },
}, "deadline_date >= ?", nil)

-- todo include shorthand (array)
assert_build({ todo = { "TODO", "NEXT" } }, "todo_state IN (?,?)", 2)

-- todo include + exclude
assert_build(
  { todo = { include = { "TODO", "NEXT" }, exclude = { "DONE" } } },
  "todo_state IN (?,?)",
  3
)

-- tags any shorthand (array) — tests default inherit=true path; checks sub-fragment
assert_build({ tags = { "work", "urgent" } }, "tag IN (?,?)", 2)

-- tags all — inherit=false to test direct-only SQL structure
assert_build(
  { tags = { all = { "work", "urgent" }, inherit = false } },
  "HAVING COUNT(DISTINCT tag) = ?",
  3
)

-- tags none — inherit=false to test direct-only SQL structure
assert_build({ tags = { none = { "archive" }, inherit = false } }, "LEFT JOIN tags", 1)

-- priority
assert_build({ priority = { "A", "B" } }, "priority IN (?,?)", 2)

-- level range
assert_build({ level = { min = 1, max = 3 } }, "level >= ? AND level <= ?", 2)

-- file exact
assert_build({ file = "/x.org" }, "file_path = ?", 1)

-- file_glob compiles to a LIKE / GLOB on file_path
assert_build({ file_glob = "**/projects/**" }, "file_path GLOB ?", 1)

-- title_match (default: match_aliases=true → two params)
assert_build({ title_match = "deploy" }, "h.title LIKE ?", 2)

-- title_match with match_aliases=false → one param, no aliases subquery
assert_build({ title_match = "deploy", match_aliases = false }, "h.title LIKE ?", 1)

-- parent_id non-recursive
assert_build({ parent_id = "h1" }, "parent_id = ?", 1)

-- parent_id recursive
assert_build({ parent_id = "h1", recursive = true }, "WITH RECURSIVE", 1)

-- has_parent true / false
assert_build({ has_parent = true }, "parent_id IS NOT NULL", 0)
assert_build({ has_parent = false }, "parent_id IS NULL", 0)

-- order_by + limit + offset
assert_build({
  order_by = { { "scheduled_date", "asc" }, { "priority", "asc" } },
  limit = 50,
  offset = 10,
}, "ORDER BY scheduled_date ASC, priority ASC LIMIT ? OFFSET ?", 2)

io.write("query builder ok\n")
os.exit(0)
