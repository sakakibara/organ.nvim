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
  assert(lines[2]:match("^|%-+%+%-+|$"), "sep preserved: " .. lines[2])
  -- Body sorted.
  assert(lines[3]:find("alice"), "row 3: " .. lines[3])
  assert(lines[4]:find("bob"))
  assert(lines[5]:find("zoe"))
end

-- Lex sort descending.
do
  local b = mk_buf({
    "| name  |",
    "|-------|",
    "| alice |",
    "| zoe   |",
    "| bob   |",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 3 })
  tab.sort_by_current_column(b, "desc")
  local lines = get_lines(b)
  assert(lines[3]:find("zoe"))
  assert(lines[4]:find("bob"))
  assert(lines[5]:find("alice"))
end

-- Numeric sort: all-numeric column sorts as numbers, not strings.
do
  local b = mk_buf({
    "| n   |",
    "|-----|",
    "| 100 |",
    "| 20  |",
    "| 3   |",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 3 })
  tab.sort_by_current_column(b, "asc")
  local lines = get_lines(b)
  -- Numeric: 3, 20, 100 (lex would put 100 first).
  assert(lines[3]:find("3"), "row 3: " .. lines[3])
  assert(lines[4]:find("20"))
  assert(lines[5]:find("100"))
end

-- Only the hline-delimited block around the cursor is sorted; other
-- blocks and every hline stay where they are (Emacs
-- `org-table-sort-lines`).
do
  local b = mk_buf({
    "| name  | n |",
    "|-------+---|",
    "| b     | 2 |",
    "| a     | 1 |",
    "|-------+---|",
    "| total | 3 |",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 2 })
  tab.sort_by_current_column(b, "asc")
  local lines = get_lines(b)
  assert_eq(#lines, 6)
  assert(lines[1]:find("name"), "header: " .. lines[1])
  assert(lines[2]:match("^|%-+%+%-+|$"), "first hline: " .. lines[2])
  assert(lines[3]:find("| a"), "row 3: " .. lines[3])
  assert(lines[4]:find("| b"), "row 4: " .. lines[4])
  assert(lines[5]:match("^|%-+%+%-+|$"), "second hline: " .. lines[5])
  assert(lines[6]:find("total"), "footer: " .. lines[6])
end

-- Cursor in the block below the second hline sorts only that block.
do
  local b = mk_buf({
    "| name | n |",
    "|------+---|",
    "| b    | 2 |",
    "| a    | 1 |",
    "|------+---|",
    "| z    | 9 |",
    "| y    | 8 |",
  })
  vim.api.nvim_win_set_cursor(0, { 6, 2 })
  tab.sort_by_current_column(b, "asc")
  local lines = get_lines(b)
  assert(lines[3]:find("| b"), "upper block untouched: " .. lines[3])
  assert(lines[4]:find("| a"), "upper block untouched: " .. lines[4])
  assert(lines[6]:find("| y"), "row 6: " .. lines[6])
  assert(lines[7]:find("| z"), "row 7: " .. lines[7])
end

-- Without any hline the whole table is one block; the first row is
-- not exempt.
do
  local b = mk_buf({
    "| name |",
    "| b    |",
    "| a    |",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 3 })
  tab.sort_by_current_column(b, "asc")
  local lines = get_lines(b)
  assert(lines[1]:find("| a"), "row 1: " .. lines[1])
  assert(lines[2]:find("| b"), "row 2: " .. lines[2])
  assert(lines[3]:find("name"), "row 3: " .. lines[3])
end

-- Sort outside a table is a no-op.
do
  local b = mk_buf({ "no table here" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert_eq(tab.sort_by_current_column(b, "asc"), false)
end

io.write("table sort ok\n")
