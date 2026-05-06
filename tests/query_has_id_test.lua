-- query.headlines({ has_id = true }) returns only headlines with explicit :ID:
-- property values; synthetic ids of the form "<path>#L<n>" are excluded.
-- Run via: nvim --headless -l tests/query_has_id_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

-- Fixture with mixed: one with :ID:, one without.
local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([[* Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:

* Beta
  Body line, no ID property.
]])
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local query = require("organ.query")

-- Without filter: both headlines.
local all = query.headlines({})
assert(#all == 2, "expected 2 headlines, got " .. #all)

-- With has_id = true: only Alpha.
local with_id = query.headlines({ has_id = true })
assert(#with_id == 1, "expected 1 with_id headline, got " .. #with_id)
assert(with_id[1].title == "Alpha")
assert(with_id[1].id == "alpha-id")

-- With has_id = false: only Beta.
local without_id = query.headlines({ has_id = false })
assert(#without_id == 1, "expected 1 without_id headline, got " .. #without_id)
assert(without_id[1].title == "Beta")

vim.fn.delete(tmp, "rf")
io.write("query has_id ok\n")
os.exit(0)
