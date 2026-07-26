-- tests/table_sort_test.lua
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

-- Lex sort ascending, header preserved.
do
  local b = mk_buf({
    "| name  | age |",
    "|-------|-----|",
    "| zoe   | 20  |",
    "| alice | 30  |",
    "| bob   | 25  |",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 3 }) -- in name column
  tab.sort_by_current_column(b, "asc")
  local lines = get_lines(b)
  -- Header row 1 + sep row 2 preserved.
  assert(lines[1]:find("name"), "header preserved: " .. lines[1])
  assert(lines[2]:match("^|%-+|%-+|$"), "sep preserved: " .. lines[2])
  -- Body sorted.
  assert(lines[3]:find("alice"), "row 3: " .. lines[3])
  assert(lines[4]:find("bob"))
  assert(lines[5]:find("zoe"))
end

-- Lex sort descending.
do
  local b = mk_buf({
    "| name  |",
    "| alice |",
    "| zoe   |",
    "| bob   |",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  tab.sort_by_current_column(b, "desc")
  local lines = get_lines(b)
  assert(lines[2]:find("zoe"))
  assert(lines[3]:find("bob"))
  assert(lines[4]:find("alice"))
end

-- Numeric sort: all-numeric column sorts as numbers, not strings.
do
  local b = mk_buf({
    "| n   |",
    "| 100 |",
    "| 20  |",
    "| 3   |",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  tab.sort_by_current_column(b, "asc")
  local lines = get_lines(b)
  -- Numeric: 3, 20, 100 (lex would put 100 first).
  assert(lines[2]:find("3"), "row 2: " .. lines[2])
  assert(lines[3]:find("20"))
  assert(lines[4]:find("100"))
end

-- Sort outside a table is a no-op.
do
  local b = mk_buf({ "no table here" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert_eq(tab.sort_by_current_column(b, "asc"), false)
end

io.write("table sort ok\n")
