-- tests/table_column_ops_test.lua
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

-- insert_column_right adds an empty column right of cursor's column.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  vim.api.nvim_win_set_cursor(0, { 1, 3 }) -- in cell 1 ("a")
  assert(tab.insert_column_right(b))
  local lines = get_lines(b)
  -- New column should appear between original cols 1 and 2 → 3 cols total.
  -- Count pipes in row 1.
  local _, n = lines[1]:gsub("|", "|")
  assert_eq(n, 4, "3 cells = 4 pipes; row 1: " .. lines[1])
end

-- insert_column_left adds empty column left of cursor's column.
do
  local b = mk_buf({ "| a | b |", "| c | d |" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- in cell 2
  assert(tab.insert_column_left(b))
  local lines = get_lines(b)
  -- Cell 1 ("a"), new empty cell, cell 3 ("b").
  assert(lines[1]:match("^|%s+a%s+|%s+|%s+b%s+|$"), "expected | a | | b |, got: " .. lines[1])
end

-- delete_column removes cursor's column from all non-separator rows.
do
  local b = mk_buf({ "| a | b | c |", "| d | e | f |" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- cell 2 ("b")
  assert(tab.delete_column(b))
  local lines = get_lines(b)
  assert(lines[1]:match("^|%s+a%s+|%s+c%s+|$"), "expected | a | c |, got: " .. lines[1])
  assert(lines[2]:match("^|%s+d%s+|%s+f%s+|$"))
end

-- move_column_left swaps cursor's column with the one to the left.
do
  local b = mk_buf({ "| a | b | c |" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- cell 2 ("b")
  assert(tab.move_column_left(b))
  local lines = get_lines(b)
  assert(lines[1]:match("^|%s+b%s+|%s+a%s+|%s+c%s+|$"), "got: " .. lines[1])
end

-- move_column_right at last column is a no-op.
do
  local b = mk_buf({ "| a | b |" })
  vim.api.nvim_win_set_cursor(0, { 1, 7 }) -- last cell
  assert_eq(tab.move_column_right(b), false)
end

io.write("table column ops ok\n")
