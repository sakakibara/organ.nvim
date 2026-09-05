-- Bound values must line up with the `?` placeholders in the order the
-- generated SQL emits them: CTEs first, then joins, then WHERE, then the
-- ORDER BY / LIMIT tail.
-- Run via: nvim --headless -l tests/query_param_order_test.lua

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

local h = require("organ").db_handle()
h:exec([[
  INSERT INTO files(path, mtime, hash, indexed) VALUES ('/x.org', 0, 'a', 0);
  INSERT INTO headlines(id, file_path, level, title, scheduled_date, line_start, line_end) VALUES
    ('h1', '/x.org', 1, 'Tagged in window',     '2026-05-05', 0, 1),
    ('h2', '/x.org', 1, 'Untagged in window',   '2026-05-06', 2, 3),
    ('h3', '/x.org', 1, 'Tagged out of window', '2026-06-01', 4, 5),
    ('h4', '/x.org', 2, 'Child of h1',          '2026-05-07', 6, 7);
  UPDATE headlines SET parent_id = 'h1' WHERE id = 'h4';
  INSERT INTO tags(headline_id, tag) VALUES ('h1', 'work'), ('h3', 'work');
]])

local query = require("organ.query")

local function titles(filters)
  local out = {}
  for _, r in ipairs(query.headlines(filters)) do
    out[#out + 1] = r.title
  end
  table.sort(out)
  return table.concat(out, "|")
end

-- A date window plus a tag join: the join's placeholder precedes both
-- WHERE placeholders in the SQL.
assert(titles({
  scheduled = { from = "2026-05-01", to = "2026-05-31" },
  tags = { any = { "work" }, inherit = false },
}) == "Tagged in window", "date + tag filter: " .. titles({
  scheduled = { from = "2026-05-01", to = "2026-05-31" },
  tags = { any = { "work" }, inherit = false },
}))

-- A recursive-parent CTE placeholder precedes the WHERE placeholders.
assert(
  titles({ parent_id = "h1", recursive = true, title_match = "Child" }) == "Child of h1",
  "recursive parent + title: "
    .. titles({ parent_id = "h1", recursive = true, title_match = "Child" })
)

-- Inherited tags come from a CTE, whose placeholders precede everything.
assert(titles({
  scheduled = { from = "2026-05-01", to = "2026-05-31" },
  tags = { any = { "work" }, inherit = true },
}) == "Child of h1|Tagged in window", "inherited tag + date: " .. titles({
  scheduled = { from = "2026-05-01", to = "2026-05-31" },
  tags = { any = { "work" }, inherit = true },
}))

-- has_property joins and binds its key in the WHERE clause.
h:exec("INSERT INTO properties(headline_id, key, value) VALUES ('h2', 'EFFORT', '1:00');")
assert(
  titles({ scheduled = { from = "2026-05-01", to = "2026-05-31" }, has_property = "EFFORT" })
    == "Untagged in window",
  "date + has_property: "
    .. titles({ scheduled = { from = "2026-05-01", to = "2026-05-31" }, has_property = "EFFORT" })
)

vim.fn.delete(tmp, "rf")
io.write("query param order ok\n")
os.exit(0)
