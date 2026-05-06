-- tests/table_formula_integration_test.lua

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

----------------------------------------------------------------------
-- Column formula: $4=$2*$3 fills total for every body row.
do
  local b = mk_buf({
    "| name  | qty | price | total |",
    "|-------+-----+-------+-------|",
    "| apple |   3 | 2     |       |",
    "| pear  |   5 | 3     |       |",
    "#+TBLFM: $4=$2*$3",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 3 }) -- in body
  tab.eval_formulas(b)
  local lines = get_lines(b)
  assert(lines[3]:find("| 6"), "row 3 total = 6: " .. lines[3])
  assert(lines[4]:find("| 15"), "row 4 total = 15: " .. lines[4])
end

----------------------------------------------------------------------
-- Cell formula: @5$2=vsum(@3$1..@4$1).
do
  local b = mk_buf({
    "| 10 |    |",
    "|----+----|",
    "| 1  |    |",
    "| 2  |    |",
    "|    |    |",
    "#+TBLFM: @5$2=vsum(@3$1..@4$1)",
  })
  vim.api.nvim_win_set_cursor(0, { 5, 3 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  -- Row 5 col 2 should be 3.
  assert(lines[5]:find("| 3"), "row 5 col 2 = 3: " .. lines[5])
end

----------------------------------------------------------------------
-- Multiple :: formulas applied in order.
do
  local b = mk_buf({
    "|  2 | 3 |    |    |",
    "#+TBLFM: $3=$1+$2 :: $4=$3*2",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  assert(lines[1]:find("| 5"), "$3 = 5: " .. lines[1])
  assert(lines[1]:find("| 10"), "$4 = 10: " .. lines[1])
end

io.write("table formula integration ok\n")
