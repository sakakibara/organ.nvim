-- tests/structure_demote_test.lua
-- Run via: nvim --headless -l tests/structure_demote_test.lua

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
-- demote_headline level-1 -> level-2.
do
  local b = mk_buf({ "* A", "** B" })
  local err = structure.demote_headline({ bufnr = b, line = 1 })
  assert(err == nil, tostring(err))
  assert_eq(get_lines(b)[1], "** A")
  assert_eq(get_lines(b)[2], "** B", "B unchanged")
end

----------------------------------------------------------------------
-- demote_headline at level-9 errors.
do
  local b = mk_buf({ "********* deep", "**** other" })
  local err = structure.demote_headline({ bufnr = b, line = 1 })
  assert(err and err:find("level 9"), "got: " .. tostring(err))
end

----------------------------------------------------------------------
-- demote_subtree increments current + descendants.
do
  local b = mk_buf({
    "* A",
    "** B",
    "  body",
    "*** C",
    "* Other",
  })
  local err = structure.demote_subtree({ bufnr = b, line = 1 })
  assert(err == nil, tostring(err))
  local out = get_lines(b)
  assert_eq(out[1], "** A")
  assert_eq(out[2], "*** B")
  assert_eq(out[4], "**** C")
  assert_eq(out[5], "* Other", "sibling untouched")
end

----------------------------------------------------------------------
-- demote_subtree where deepest descendant is at level 9 errors atomically.
do
  local b = mk_buf({
    "** A",
    "********* deep",
  })
  local err = structure.demote_subtree({ bufnr = b, line = 1 })
  assert(err and err:find("level 9"), "got: " .. tostring(err))
  -- Atomic: nothing was changed.
  assert_eq(get_lines(b)[1], "** A", "no partial write")
  assert_eq(get_lines(b)[2], "********* deep")
end

io.write("structure demote ok\n")
