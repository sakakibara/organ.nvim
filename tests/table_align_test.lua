-- tests/table_align_test.lua
-- Run via: nvim --headless -l tests/table_align_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

----------------------------------------------------------------------
-- Mixed-width cells pad to the longest.
do
  local rows = {
    { cells = { "name", "age" }, sep = false },
    { cells = { "alice", "30" }, sep = false },
  }
  local out = tab._align(rows, "")
  assert_eq(out[1], "| name  | age |")
  assert_eq(out[2], "| alice | 30  |")
end

----------------------------------------------------------------------
-- Separator row matches column widths (count of dashes = width + 2).
do
  local rows = {
    { cells = { "name", "age" }, sep = false },
    { cells = { "", "" }, sep = true },
    { cells = { "alice", "30" }, sep = false },
  }
  local out = tab._align(rows, "")
  -- "alice" width 5 → 7 dashes; "age" width 3 → 5 dashes
  assert_eq(out[2], "|-------|-----|", "separator dashes match widths +2")
end

----------------------------------------------------------------------
-- Empty cells render as ' ' padded to column width.
do
  local rows = {
    { cells = { "name", "age" }, sep = false },
    { cells = { "alice", "" }, sep = false },
  }
  local out = tab._align(rows, "")
  assert_eq(out[2], "| alice |     |")
end

----------------------------------------------------------------------
-- Single-column table.
do
  local rows = { { cells = { "x" }, sep = false }, { cells = { "yyy" }, sep = false } }
  local out = tab._align(rows, "")
  assert_eq(out[1], "| x   |")
  assert_eq(out[2], "| yyy |")
end

----------------------------------------------------------------------
-- Indented align.
do
  local rows = { { cells = { "a", "b" }, sep = false } }
  local out = tab._align(rows, "  ")
  assert_eq(out[1], "  | a | b |")
end

io.write("table align ok\n")
