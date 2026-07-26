-- tests/table_row_ops_test.lua
-- Run via: nvim --headless -l tests/table_row_ops_test.lua

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

-- insert_row_below adds empty row at row+1.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  assert(tab.insert_row_below(b))
  local lines = get_lines(b)
  assert_eq(#lines, 3)
  -- Row 2 is the new empty row, row 3 is the original second row.
  assert(
    lines[2]:match("^|%s+|%s+|$") or lines[2]:match("^|%s+|%s+|%s*$"),
    "row 2 empty: " .. lines[2]
  )
  assert(lines[3]:find("c"), "row 3 has 'c': " .. lines[3])
end

-- insert_row_above adds empty row at row.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  vim.api.nvim_win_set_cursor(0, { 2, 3 }) -- on second row
  assert(tab.insert_row_above(b))
  local lines = get_lines(b)
  assert_eq(#lines, 3)
  assert(lines[1]:find("a"), "row 1 still 'a'")
  assert(lines[2]:match("^|%s+|%s+|$") or lines[2]:match("^|%s+|%s+|%s*$"), "row 2 empty")
  assert(lines[3]:find("c"))
end

-- delete_row removes cursor's row.
do
  local b = mk_buf({ "| a | b |", "| c | d |", "| e | f |" })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  assert(tab.delete_row(b))
  local lines = get_lines(b)
  assert_eq(#lines, 2)
  assert(lines[1]:find("a"))
  assert(lines[2]:find("e"))
end

-- move_row_up swaps with previous row.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  vim.api.nvim_win_set_cursor(0, { 2, 3 }) -- on second row
  assert(tab.move_row_up(b))
  local lines = get_lines(b)
  assert(lines[1]:find("c"), "c moved to row 1: " .. lines[1])
  assert(lines[2]:find("a"))
end

-- move_row_up at first row is a no-op (returns false).
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  assert_eq(tab.move_row_up(b), false)
  -- Buffer unchanged.
  local lines = get_lines(b)
  assert(lines[1]:find("a"))
end

-- move_row_down swaps with next row.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 })
  assert(tab.move_row_down(b))
  local lines = get_lines(b)
  assert(lines[1]:find("c"))
  assert(lines[2]:find("a"))
end

io.write("table row ops ok\n")
