-- tests/structure_cursor_test.lua
-- Run via: nvim --headless -l tests/structure_cursor_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local structure = require("organ.structure")

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

----------------------------------------------------------------------
-- Cursor on headline line returns that headline.
do
  local b = mk_buf({ "* A", "  body", "** A1", "* B" })
  local hl = structure._find_containing_headline(b, 1)
  assert(hl, "found headline at line 1")
  assert_eq(hl.line, 1)
  assert_eq(hl.level, 1)
  assert_eq(hl.title_text, "A")
end

----------------------------------------------------------------------
-- Cursor on body text resolves to containing headline.
do
  local b = mk_buf({ "* A", "  body", "  more body", "** A1" })
  local hl = structure._find_containing_headline(b, 3)
  assert_eq(hl.line, 1, "body resolves to parent headline")
end

----------------------------------------------------------------------
-- Cursor on sub-headline returns sub-headline (the one it's actually on).
do
  local b = mk_buf({ "* A", "** A1", "   sub body" })
  local hl = structure._find_containing_headline(b, 2)
  assert_eq(hl.line, 2)
  assert_eq(hl.level, 2)
end

----------------------------------------------------------------------
-- Cursor before any headline returns nil.
do
  local b = mk_buf({ "before any heading", "* A" })
  local hl = structure._find_containing_headline(b, 1)
  assert_eq(hl, nil, "no enclosing headline")
end

----------------------------------------------------------------------
-- Subtree end calculation.
do
  local b = mk_buf({ "* A", "  body", "** A1", "   x", "** A2", "* B" })
  local hl = structure._find_containing_headline(b, 1)
  local subtree_end = structure._subtree_end(b, hl)
  assert_eq(subtree_end, 5, "subtree of A ends at line 5 (last A2 body line)")
end

----------------------------------------------------------------------
-- Subtree end at end of buffer.
do
  local b = mk_buf({ "* A", "** A1" })
  local hl = structure._find_containing_headline(b, 1)
  local subtree_end = structure._subtree_end(b, hl)
  assert_eq(subtree_end, 2, "subtree extends to end of buffer")
end

io.write("structure cursor ok\n")
