-- tests/table_parse_test.lua
-- Run via: nvim --headless -l tests/table_parse_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- Single 2-row, 2-col table.
do
  local lines = { "| a | b |", "| c | d |" }
  local t = tab._parse(lines, 1)
  assert(t, "parsed")
  assert_eq(t.start_line, 1)
  assert_eq(t.end_line, 2)
  assert_eq(#t.rows, 2)
  assert_eq(t.rows[1].cells[1], "a")
  assert_eq(t.rows[1].cells[2], "b")
  assert_eq(t.rows[1].sep, false)
  assert_eq(t.rows[2].cells[1], "c")
  assert_eq(t.rows[2].cells[2], "d")
end

-- Table with separator row.
do
  local lines = { "| a | b |", "|---|---|", "| c | d |" }
  local t = tab._parse(lines, 2)
  assert_eq(#t.rows, 3)
  assert_eq(t.rows[2].sep, true, "separator row detected")
  assert_eq(t.rows[1].sep, false)
  assert_eq(t.rows[3].sep, false)
end

-- Cursor on non-table line returns nil.
do
  local lines = { "before", "| a |", "after" }
  assert_eq(tab._parse(lines, 1), nil)
  assert_eq(tab._parse(lines, 3), nil)
  assert(tab._parse(lines, 2), "table line parses")
end

-- Indented table preserves indent.
do
  local lines = { "  | a |", "  | b |" }
  local t = tab._parse(lines, 1)
  assert_eq(t.indent, "  ")
end

-- Walks up + down from middle line.
do
  local lines = { "x", "| 1 |", "| 2 |", "| 3 |", "y" }
  local t = tab._parse(lines, 3)
  assert_eq(t.start_line, 2)
  assert_eq(t.end_line, 4)
  assert_eq(#t.rows, 3)
end

io.write("table parse ok\n")
