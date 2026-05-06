-- maybe_open dedupes against (row, prefix_col); different positions re-open.
-- Uses the _test_stub backend to capture picker invocations without snacks.
-- Run via: nvim --headless -l tests/complete_maybe_open_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.opt.virtualedit = "onemore"

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([=[* Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:
]=])
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

local complete = require("organ.complete")
local stub = require("organ.find.backend")._test_stub

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "[[id:" })
vim.api.nvim_set_current_buf(b)
vim.api.nvim_win_set_cursor(0, { 1, 5 })

stub.last = nil
complete.maybe_open(b)
assert(stub.last, "first maybe_open should fire picker")

stub.last = nil
complete.maybe_open(b)
assert(stub.last == nil, "second maybe_open same position should be no-op")

vim.api.nvim_buf_set_lines(b, 0, -1, false, { "[[id:", "[[id:" })
vim.api.nvim_win_set_cursor(0, { 2, 5 })
stub.last = nil
complete.maybe_open(b)
assert(stub.last, "different position should re-open picker")

vim.api.nvim_buf_set_lines(b, 0, -1, false, { "no trigger here" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
complete.maybe_open(b)

vim.api.nvim_buf_set_lines(b, 0, -1, false, { "[[id:" })
vim.api.nvim_win_set_cursor(0, { 1, 5 })
stub.last = nil
complete.maybe_open(b)
assert(stub.last, "after state clear, should re-open at original position")

vim.fn.delete(tmp, "rf")
io.write("complete maybe_open ok\n")
os.exit(0)
