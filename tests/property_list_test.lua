-- tests/property_list_test.lua
-- Run via: nvim --headless -l tests/property_list_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local prop = require("organ.property")

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
-- No drawer: returns empty list.
do
  local b = mk_buf({ "* A", "  body" })
  local out = prop.list(b, 1)
  assert(out, "list non-nil for headline")
  assert_eq(#out, 0)
end

----------------------------------------------------------------------
-- With drawer: returns parsed entries in order.
do
  local b = mk_buf({
    "* A",
    ":PROPERTIES:",
    ":ID: abc-123",
    ":CATEGORY: work",
    ":END:",
    "  body",
  })
  local out = prop.list(b, 1)
  assert_eq(#out, 2)
  assert_eq(out[1].key, "ID")
  assert_eq(out[1].value, "abc-123")
  assert_eq(out[2].key, "CATEGORY")
  assert_eq(out[2].value, "work")
end

----------------------------------------------------------------------
-- Cursor in body resolves up to headline.
do
  local b = mk_buf({ "* A", ":PROPERTIES:", ":KEY: v", ":END:", "  body" })
  local out = prop.list(b, 5)
  assert_eq(#out, 1)
  assert_eq(out[1].key, "KEY")
end

----------------------------------------------------------------------
-- No headline returns nil.
do
  local b = mk_buf({ "before any heading", "" })
  local out = prop.list(b, 1)
  assert_eq(out, nil)
end

----------------------------------------------------------------------
-- After planning lines, drawer still found.
do
  local b = mk_buf({
    "* TODO X",
    "SCHEDULED: <2026-04-27 Mon>",
    ":PROPERTIES:",
    ":ID: xyz",
    ":END:",
  })
  local out = prop.list(b, 1)
  assert_eq(#out, 1)
  assert_eq(out[1].key, "ID")
end

io.write("property list ok\n")
