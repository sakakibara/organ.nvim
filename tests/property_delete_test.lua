-- tests/property_delete_test.lua
-- Run via: nvim --headless -l tests/property_delete_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local prop = require("organ.property")

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
-- Delete existing key removes the line.
do
  local b = mk_buf({
    "* A",
    ":PROPERTIES:",
    ":ID: abc",
    ":CATEGORY: work",
    ":END:",
  })
  local err = prop.delete(b, 1, "ID")
  assert_eq(err, nil)
  local lines = get_lines(b)
  assert_eq(lines[2], ":PROPERTIES:")
  assert_eq(lines[3], ":CATEGORY: work")
  assert_eq(lines[4], ":END:")
  assert_eq(#lines, 4)
end

----------------------------------------------------------------------
-- Delete last property removes the entire drawer.
do
  local b = mk_buf({
    "* A",
    ":PROPERTIES:",
    ":ID: only-one",
    ":END:",
    "  body",
  })
  local err = prop.delete(b, 1, "ID")
  assert_eq(err, nil)
  local lines = get_lines(b)
  assert_eq(lines[1], "* A")
  assert_eq(lines[2], "  body")
  assert_eq(#lines, 2)
end

----------------------------------------------------------------------
-- Delete non-existent key returns error.
do
  local b = mk_buf({ "* A", ":PROPERTIES:", ":ID: a", ":END:" })
  local err = prop.delete(b, 1, "MISSING")
  assert(err and err:find("not set"), "got: " .. tostring(err))
  -- buffer unchanged
  assert_eq(get_lines(b)[3], ":ID: a")
end

----------------------------------------------------------------------
-- Delete from no-drawer headline returns error.
do
  local b = mk_buf({ "* A" })
  local err = prop.delete(b, 1, "FOO")
  assert(err and err:find("not set"), "got: " .. tostring(err))
end

----------------------------------------------------------------------
-- Delete preserves order of other properties.
do
  local b = mk_buf({
    "* A",
    ":PROPERTIES:",
    ":A: 1",
    ":B: 2",
    ":C: 3",
    ":END:",
  })
  prop.delete(b, 1, "B")
  local lines = get_lines(b)
  assert_eq(lines[3], ":A: 1")
  assert_eq(lines[4], ":C: 3")
  assert_eq(lines[5], ":END:")
end

io.write("property delete ok\n")
