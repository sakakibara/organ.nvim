-- `title_match` is a literal substring search (what `:Org agenda search`
-- documents), so LIKE metacharacters in the needle match themselves.
-- Run via: nvim --headless -l tests/query_title_match_escape_test.lua

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
  INSERT INTO headlines(id, file_path, level, title, line_start, line_end) VALUES
    ('h1', '/x.org', 1, '100% done',         0, 1),
    ('h2', '/x.org', 1, '100 percent done',  2, 3),
    ('h3', '/x.org', 1, 'a_b',               4, 5),
    ('h4', '/x.org', 1, 'axb',               6, 7),
    ('h5', '/x.org', 1, 'back\slash',        8, 9),
    ('h6', '/x.org', 1, 'backslash',        10, 11);
  INSERT INTO aliases(headline_id, alias) VALUES ('h6', '100% alias');
]])

local query = require("organ.query")

local function titles(needle, opts)
  local filters = vim.tbl_extend("force", {
    title_match = needle,
    order_by = { { "line_start", "asc" } },
  }, opts or {})
  local out = {}
  for _, r in ipairs(query.headlines(filters)) do
    out[#out + 1] = r.title
  end
  return table.concat(out, "|")
end

assert(titles("a_b") == "a_b", "_ wildcarded: " .. titles("a_b"))
assert(titles("back\\") == "back\\slash", "backslash mishandled: " .. titles("back\\"))
assert(
  titles("100% done", { match_aliases = false }) == "100% done",
  "% wildcarded: " .. titles("100% done", { match_aliases = false })
)
assert(
  titles("100%", { match_aliases = false }) == "100% done",
  "% wildcarded: " .. titles("100%", { match_aliases = false })
)

-- The alias branch of the same filter escapes identically: h6's alias
-- contains the literal "100%", h2's title does not.
assert(
  titles("100%", { match_aliases = true }) == "100% done|backslash",
  "alias LIKE unescaped: " .. titles("100%", { match_aliases = true })
)

vim.fn.delete(tmp, "rf")
io.write("query title match escape ok\n")
os.exit(0)
