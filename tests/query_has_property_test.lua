-- query.headlines({ has_property = "ROAM_REFS" }) returns only headlines that
-- have a property with that key.
-- Run via: nvim --headless -l tests/query_has_property_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([[* Alpha
  :PROPERTIES:
  :ID:        alpha-id
  :ROAM_REFS: cite:knuth1968
  :END:

* Beta
  :PROPERTIES:
  :ID:        beta-id
  :END:

* Gamma
  No properties at all.
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

local refs = query.headlines({ has_property = "ROAM_REFS" })
assert(#refs == 1, "expected 1 headline with ROAM_REFS, got " .. #refs)
assert(refs[1].title == "Alpha")

-- Unknown key: empty result.
local none = query.headlines({ has_property = "DOES_NOT_EXIST" })
assert(#none == 0, "expected 0 headlines for unknown key, got " .. #none)

vim.fn.delete(tmp, "rf")
io.write("query has_property ok\n")
os.exit(0)
