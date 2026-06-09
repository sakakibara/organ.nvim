-- id / headline / property_value completion must bound the DB query so a
-- large org-roam corpus can't produce a giant synchronous result + tag
-- hydration on the keystroke. The cap is complete.query_max_results.
-- Run via: nvim --headless -l tests/complete_query_limit_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/org", "p")
local lines = {}
for i = 1, 8 do
  lines[#lines + 1] = "* Heading " .. i
  lines[#lines + 1] = ":PROPERTIES:"
  lines[#lines + 1] = ":ID: id-" .. i
  lines[#lines + 1] = ":END:"
end
vim.fn.writefile(lines, tmp .. "/org/x.org")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = tmp .. "/org",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
  complete = { query_max_results = 3 },
})
require("organ").scan_blocking(tmp .. "/org", 5000)

local complete = require("organ.complete")

local id_items = complete.items_for("id")
assert(#id_items == 3, "expected id completion capped at 3, got " .. #id_items)

local hl_items = complete.items_for("headline")
assert(#hl_items == 3, "expected headline completion capped at 3, got " .. #hl_items)

vim.fn.delete(tmp, "rf")
io.write("complete query limit ok\n")
os.exit(0)
