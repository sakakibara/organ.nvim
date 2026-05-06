-- table_edit: open + commit a cell value end-to-end.
-- Run via: nvim --headless -l tests/table_edit_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local te = require("organ.table_edit")

-- Build a buffer with a known table.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "intro",
  "| name  | age |",
  "|-------+-----|",
  "| ada   |  36 |",
  "| ben   |  41 |",
})
vim.api.nvim_set_current_buf(b)
-- Cursor on the `ada` cell (line 4, col over `a`).
vim.api.nvim_win_set_cursor(0, { 4, 3 })

-- Open + commit a new value via the popup buffer.
te.open(b, 4)
local pop = vim.api.nvim_get_current_buf()
assert(pop ~= b, "popup should be a separate buffer")
assert(
  vim.api.nvim_buf_get_lines(pop, 0, -1, false)[1] == "ada",
  "popup pre-populated with current cell text"
)
vim.api.nvim_buf_set_lines(pop, 0, -1, false, { "alice" })

-- Trigger the buffer-local <CR> normal-mode mapping by calling its callback.
local maps = vim.api.nvim_buf_get_keymap(pop, "n")
local cr_cb
for _, m in ipairs(maps) do
  if m.lhs == "<CR>" and m.callback then
    cr_cb = m.callback
    break
  end
end
assert(cr_cb, "expected <CR> mapping in popup")
cr_cb()

-- Source buffer should now show the renamed cell, realigned.
local body = vim.api.nvim_buf_get_lines(b, 0, -1, false)
local row3 = body[4]
assert(row3:find("alice", 1, true), "renamed cell present in row: " .. row3)
assert(not row3:find("ada", 1, true), "old text replaced")

-- Newlines collapse to spaces.
vim.api.nvim_win_set_cursor(0, { 5, 3 })
te.open(b, 5)
local pop2 = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(pop2, 0, -1, false, { "first", "second" })
local maps2 = vim.api.nvim_buf_get_keymap(pop2, "n")
for _, m in ipairs(maps2) do
  if m.lhs == "<CR>" and m.callback then
    m.callback()
    break
  end
end
local body2 = vim.api.nvim_buf_get_lines(b, 0, -1, false)
local row4 = body2[5]
assert(row4:find("first second", 1, true), "newlines collapsed to space; got: " .. row4)

io.write("table edit ok\n")
os.exit(0)
