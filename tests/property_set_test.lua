-- tests/property_set_test.lua
-- Run via: nvim --headless -l tests/property_set_test.lua

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
-- Set creates drawer when absent.
do
  local b = mk_buf({ "* A", "  body" })
  local err = prop.set(b, 1, "ID", "abc")
  assert_eq(err, nil)
  local lines = get_lines(b)
  assert_eq(lines[2], "  :PROPERTIES:")
  assert_eq(lines[3], "  :ID:       abc")
  assert_eq(lines[4], "  :END:")
  assert_eq(lines[5], "  body")
end

----------------------------------------------------------------------
-- Set existing key updates value in place.
do
  local b = mk_buf({ "* A", ":PROPERTIES:", ":ID: old", ":END:" })
  local err = prop.set(b, 1, "ID", "new")
  assert_eq(err, nil)
  local lines = get_lines(b)
  assert_eq(lines[3], ":ID:       new")
  assert_eq(#lines, 4)
end

----------------------------------------------------------------------
-- Set new key appends before :END:.
do
  local b = mk_buf({ "* A", ":PROPERTIES:", ":ID: a", ":END:" })
  local err = prop.set(b, 1, "CATEGORY", "work")
  assert_eq(err, nil)
  local lines = get_lines(b)
  assert_eq(lines[3], ":ID: a")
  assert_eq(lines[4], ":CATEGORY: work")
  assert_eq(lines[5], ":END:")
end

----------------------------------------------------------------------
-- Set creates drawer correctly placed: after planning, before LOGBOOK.
do
  local b = mk_buf({
    "* TODO X",
    "SCHEDULED: <2026-04-27 Mon>",
    ":LOGBOOK:",
    ":END:",
    "  body",
  })
  local err = prop.set(b, 1, "ID", "abc")
  assert_eq(err, nil)
  local lines = get_lines(b)
  assert_eq(lines[1], "* TODO X")
  assert_eq(lines[2], "SCHEDULED: <2026-04-27 Mon>")
  assert_eq(lines[3], "  :PROPERTIES:")
  assert_eq(lines[4], "  :ID:       abc")
  assert_eq(lines[5], "  :END:")
  assert_eq(lines[6], ":LOGBOOK:")
end

----------------------------------------------------------------------
-- Invalid key (contains ":") errors, no buffer change.
do
  local b = mk_buf({ "* A" })
  local err = prop.set(b, 1, "BAD:KEY", "v")
  assert(err and err:find("invalid property key"), "got: " .. tostring(err))
  assert_eq(get_lines(b)[1], "* A")
  assert_eq(#get_lines(b), 1)
end

----------------------------------------------------------------------
-- Empty value stored as a bare ':KEY:' (Emacs `org-property-format` writes
-- no padding or trailing space when the value is empty).
do
  local b = mk_buf({ "* A" })
  prop.set(b, 1, "FOO", "")
  local lines = get_lines(b)
  assert_eq(lines[3], "  :FOO:")
end

----------------------------------------------------------------------
-- Set with no headline returns error.
do
  local b = mk_buf({ "before", "" })
  local err = prop.set(b, 1, "ID", "v")
  assert(err and err:find("not on a headline"), "got: " .. tostring(err))
end

----------------------------------------------------------------------
-- Newline in value is rejected (would corrupt the property drawer parse
-- on round-trip — `:KEY: line1\nline2` becomes two malformed lines).
do
  local b = mk_buf({ "* A" })
  local err = prop.set(b, 1, "FOO", "line1\nline2")
  assert(err and err:find("newline"), "expected newline-rejection error; got: " .. tostring(err))
  local lines = get_lines(b)
  assert(
    #lines == 1 and lines[1] == "* A",
    "buffer must be unchanged on rejected set; got: " .. table.concat(lines, "|")
  )
end

----------------------------------------------------------------------
-- Carriage return in value also rejected.
do
  local b = mk_buf({ "* A" })
  local err = prop.set(b, 1, "FOO", "with\rCR")
  assert(err and err:find("newline"), "expected CR-rejection error; got: " .. tostring(err))
end

io.write("property set ok\n")
