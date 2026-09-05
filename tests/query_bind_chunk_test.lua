-- Hydration binds one parameter per result row, so it splits the `IN`
-- lists into chunks that stay under SQLITE_MAX_VARIABLE_NUMBER. Driving
-- the split with a tiny chunk size proves every chunk is applied.
-- Run via: nvim --headless -l tests/query_bind_chunk_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  org_dir = tmp,
  db_path = tmp .. "/organ.db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local N = 17
local h = require("organ").db_handle()
h:exec("INSERT INTO files(path, mtime, hash, indexed) VALUES ('/x.org', 0, 'a', 0);")
h:exec("INSERT INTO file_tags(file_path, tag) VALUES ('/x.org', 'filetag');")
for i = 1, N do
  local id = "h" .. i
  h:exec(
    string.format(
      "INSERT INTO headlines(id, file_path, level, title, line_start, line_end) "
        .. "VALUES ('%s', '/x.org', 1, 'T%d', %d, %d);",
      id,
      i,
      i,
      i
    )
  )
  h:exec(string.format("INSERT INTO tags(headline_id, tag) VALUES ('%s', 'work');", id))
  h:exec(
    string.format("INSERT INTO properties(headline_id, key, value) VALUES ('%s', 'K', 'v');", id)
  )
  h:exec(
    string.format(
      "INSERT INTO links(source_headline_id, target_type, target, line) "
        .. "VALUES ('%s', 'id', 'h1', 1);",
      id
    )
  )
  h:exec(
    string.format(
      "INSERT INTO habit_completions(headline_id, date) VALUES ('%s', '2026-05-04');",
      id
    )
  )
end

local exec = require("organ.query.exec")
exec._bind_chunk = 3

local query = require("organ.query")
local rows = query.headlines({
  include_properties = true,
  include_inherited_tags = true,
  include_backlink_counts = true,
  order_by = { { "line_start", "asc" } },
})
assert(#rows == N, "expected " .. N .. " rows, got " .. #rows)
for _, r in ipairs(rows) do
  assert(vim.tbl_contains(r.tags, "work"), r.id .. " lost its direct tag")
  assert(vim.tbl_contains(r.tags, "filetag"), r.id .. " lost its inherited filetag")
  assert(r.properties.K == "v", r.id .. " lost its property")
end
assert(rows[1].backlink_count == N, "backlink count " .. tostring(rows[1].backlink_count))

local ids = {}
for i = 1, N do
  ids[i] = "h" .. i
end
local completions = query.habit_completions({ headline_id = ids })
local n_completions = 0
for _ in pairs(completions) do
  n_completions = n_completions + 1
end
assert(n_completions == N, "habit completions covered " .. n_completions .. " headlines")

exec._bind_chunk = 500
vim.fn.delete(tmp, "rf")
io.write("query bind chunk ok\n")
os.exit(0)
