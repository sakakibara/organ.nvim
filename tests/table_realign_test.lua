-- tests/table_realign_test.lua
-- Run via: nvim --headless -l tests/table_realign_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

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

-- realign rewrites the table block; outside lines untouched.
do
  local b = mk_buf({
    "before",
    "|name|age|",
    "|alice|30|",
    "after",
  })
  tab.realign(b, 2)
  local lines = get_lines(b)
  assert_eq(lines[1], "before")
  assert_eq(lines[2], "| name  | age |")
  assert_eq(lines[3], "| alice |  30 |")
  assert_eq(lines[4], "after")
end

-- Indent preserved.
do
  local b = mk_buf({ "  |a|b|", "  |c|d|" })
  tab.realign(b, 1)
  assert_eq(get_lines(b)[1], "  | a | b |")
end

-- realign on non-table line is a no-op.
do
  local b = mk_buf({ "no pipes here" })
  tab.realign(b, 1)
  assert_eq(get_lines(b)[1], "no pipes here")
end

io.write("table realign ok\n")
