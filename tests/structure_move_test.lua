-- tests/structure_move_test.lua
-- Run via: nvim --headless -l tests/structure_move_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local structure = require("organ.structure")

local function mk_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
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
-- move_subtree_up swaps with previous sibling, preserving body content.
do
  local b = mk_buf({
    "* A",
    "  body of A",
    "** A1",
    "* B",
    "  body of B",
  })
  local err = structure.move_subtree_up({ bufnr = b, line = 4 }) -- on B
  assert(err == nil, tostring(err))
  local out = get_lines(b)
  assert_eq(out[1], "* B")
  assert_eq(out[2], "  body of B")
  assert_eq(out[3], "* A")
  assert_eq(out[4], "  body of A")
  assert_eq(out[5], "** A1")
end

----------------------------------------------------------------------
-- move_subtree_down swaps with next sibling.
do
  local b = mk_buf({
    "* A",
    "* B",
    "  body of B",
    "* C",
  })
  local err = structure.move_subtree_down({ bufnr = b, line = 1 }) -- on A, first sibling
  assert(err == nil, tostring(err))
  local out = get_lines(b)
  assert_eq(out[1], "* B")
  assert_eq(out[2], "  body of B")
  assert_eq(out[3], "* A")
  assert_eq(out[4], "* C")
end

----------------------------------------------------------------------
-- move_subtree_up at first sibling errors.
do
  local b = mk_buf({ "* A", "* B" })
  local err = structure.move_subtree_up({ bufnr = b, line = 1 })
  assert(err and err:find("no previous sibling"), "got: " .. tostring(err))
  assert_eq(get_lines(b)[1], "* A", "buffer unchanged")
end

----------------------------------------------------------------------
-- move_subtree_down at last sibling errors.
do
  local b = mk_buf({ "* A", "* B" })
  local err = structure.move_subtree_down({ bufnr = b, line = 2 })
  assert(err and err:find("no next sibling"), "got: " .. tostring(err))
  assert_eq(get_lines(b)[2], "* B")
end

----------------------------------------------------------------------
-- move with sub-headlines preserves nested structure.
do
  local b = mk_buf({
    "* A",
    "** A1",
    "** A2",
    "* B",
    "** B1",
  })
  structure.move_subtree_up({ bufnr = b, line = 4 }) -- on B
  local out = get_lines(b)
  assert_eq(out[1], "* B")
  assert_eq(out[2], "** B1")
  assert_eq(out[3], "* A")
  assert_eq(out[4], "** A1")
  assert_eq(out[5], "** A2")
end

io.write("structure move ok\n")
