-- :Org complete is registered; auto-trigger autocmd is installed for FileType=org.
-- Run via: nvim --headless -l tests/orgcomplete_command_test.lua

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
  find = { backend = "_test_stub" },
})

assert(vim.api.nvim_get_commands({}).Org, ":Org not registered")
assert(require("organ").cmd("complete"), "subcommand `complete` not registered in :Org dispatcher")

local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write("placeholder\n")
fh:close()
vim.cmd("edit " .. vim.fn.fnameescape(fixture))
vim.bo.filetype = "org"
local b = vim.api.nvim_get_current_buf()

local autocmds = vim.api.nvim_get_autocmds({ buffer = b, event = "TextChangedI" })
assert(#autocmds > 0, "TextChangedI autocmd should be installed for org buffers")

local ok = pcall(vim.cmd, "Org complete")
assert(ok, ":Org complete should not raise")

vim.fn.delete(tmp, "rf")
io.write("orgcomplete command ok\n")
os.exit(0)
