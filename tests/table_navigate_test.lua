-- tests/table_navigate_test.lua
-- Run via: nvim --headless -l tests/table_navigate_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  return b
end

local function get_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

----------------------------------------------------------------------
-- Tab from cell 1 of row 1 → cell 2 of row 1.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  -- Cursor on "a" (1-based col 4 → 0-based 3).
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local moved = tab.tab(b)
  assert(moved, "tab returned true (handled)")
  local pos = vim.api.nvim_win_get_cursor(0)
  -- Cell 2 content starts at the char after "| a | " — col 7 (0-based 6, 1-based 7).
  assert_eq(pos[1], 1, "stayed in row 1")
  -- Cursor should land on the "b" cell content position (we accept anywhere within cell 2).
  -- Just verify it moved past the first | block.
  assert(pos[2] >= 6, "cursor advanced past cell 1")
end

----------------------------------------------------------------------
-- Tab from last cell of row 1 → cell 1 of row 2.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  -- Cursor on "b" (cell 2 of row 1).
  vim.api.nvim_win_set_cursor(0, { 1, 7 })
  tab.tab(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  assert_eq(pos[1], 2, "moved to row 2")
end

----------------------------------------------------------------------
-- Tab from last cell of last row → new empty row created.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  -- Cursor on "d" (last cell of last row).
  vim.api.nvim_win_set_cursor(0, { 2, 7 })
  tab.tab(b)
  local lines = get_lines(b)
  assert_eq(#lines, 3, "new row appended")
  assert(lines[3]:match("^|"), "new row has pipes")
  assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3)
end

----------------------------------------------------------------------
-- shift_tab from cell 1 of row 1 returns false (caller falls through).
do
  local b = mk_buf({ "| a | b |" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  local moved = tab.shift_tab(b)
  assert_eq(moved, false, "no prev cell → false (fallthrough)")
end

----------------------------------------------------------------------
-- Tab on a non-table line returns false.
do
  local b = mk_buf({ "no table" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert_eq(tab.tab(b), false)
end

io.write("table navigate ok\n")
