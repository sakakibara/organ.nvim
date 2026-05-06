-- :Org indent_mode toggles attach/detach; "on" / "off" variants are explicit.
-- Run via: nvim --headless -l tests/orgindentmode_command_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

assert(vim.api.nvim_get_commands({}).Org, ":Org dispatcher not registered")
assert(require("organ").cmd("indent_mode"), "subcommand `indent_mode` not registered on :Org")

-- Open an org buffer.
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write("* Top\n** Sub\n")
fh:close()
vim.cmd("edit " .. vim.fn.fnameescape(fixture))
vim.bo.filetype = "org"
local b = vim.api.nvim_get_current_buf()

local indent = require("organ.indent")

-- Initially off.
assert(not indent._attached[b], "indent should start detached")

-- Toggle on.
vim.cmd("Org indent_mode")
assert(indent._attached[b], ":Org indent_mode (toggle) should attach")

-- Toggle off.
vim.cmd("Org indent_mode")
assert(not indent._attached[b], ":Org indent_mode (toggle) should detach")

-- Explicit on.
vim.cmd("Org indent_mode on")
assert(indent._attached[b], ":Org indent_mode on should attach")

-- "on" again is idempotent (already attached).
vim.cmd("Org indent_mode on")
assert(indent._attached[b], ":Org indent_mode on (idempotent) should keep attached")

-- Explicit off.
vim.cmd("Org indent_mode off")
assert(not indent._attached[b], ":Org indent_mode off should detach")

vim.fn.delete(tmp, "rf")
io.write("orgindentmode command ok\n")
os.exit(0)
