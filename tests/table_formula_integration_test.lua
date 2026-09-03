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

local function cells(line)
  local out = {}
  for c in line:gmatch("|([^|]*)") do
    out[#out + 1] = c:match("^%s*(.-)%s*$")
  end
  out[#out] = nil
  return out
end

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

-- Cell formula: @N counts data rows only, so the hline on line 2 is
-- skipped and @4 is the 5th buffer line (Emacs `org-table-dlines`).
do
  local b = mk_buf({
    "| 10 |    |",
    "|----+----|",
    "| 1  |    |",
    "| 2  |    |",
    "|    |    |",
    "#+TBLFM: @4$2=vsum(@2$1..@3$1)",
  })
  vim.api.nvim_win_set_cursor(0, { 5, 3 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  assert_eq(cells(lines[5])[2], "3", "@4$2 lands on buffer line 5")
  assert_eq(cells(lines[4])[2], "", "buffer line 4 untouched")
end

-- Plain @R$C reference across an hline.
do
  local b = mk_buf({
    "| 10 |    |",
    "|----+----|",
    "| 1  |    |",
    "| 2  |    |",
    "| x  |    |",
    "#+TBLFM: @4$2=@2$1",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  assert_eq(cells(lines[5])[2], "1", "@2$1 is the first row after the hline")
  assert_eq(cells(lines[4])[2], "", "line 4 untouched")
end

-- Column formulas skip every line above the first hline, not just the
-- first one (Emacs `org-table-recalculate` starts after the header).
do
  local b = mk_buf({
    "| a    | b    | c   |",
    "| unit | unit | sum |",
    "|------+------+-----|",
    "| 1    | 2    |     |",
    "#+TBLFM: $3=$1+$2",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  assert_eq(cells(lines[2])[3], "sum", "second header line untouched")
  assert_eq(cells(lines[4])[3], "3", "body row computed")
end

-- An hline with no data line above it is not a header boundary.
do
  local b = mk_buf({
    "|---+---+---|",
    "| 1 | 2 |   |",
    "| 3 | 4 |   |",
    "#+TBLFM: $3=$1+$2",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 1 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  assert_eq(cells(lines[2])[3], "3")
  assert_eq(cells(lines[3])[3], "7")
end

-- Results use Calc's `(float 8)` display: 8 significant digits,
-- scientific notation outside 1e-2..1e11, trailing "." on integral
-- floats, exact integers otherwise.
do
  local b = mk_buf({
    "| 1     | 3      |   |",
    "| 1     | 1024   |   |",
    "| 2     | 4      |   |",
    "| 3     | 1.5    |   |",
    "| 4     | 2      |   |",
    "| 0.1   | 0.2    |   |",
    "| 1e11  | 1      |   |",
    "| 1e12  | 1      |   |",
    "| 1     | 30     |   |",
    "| 1     | 300    |   |",
    "| -1    | 1024   |   |",
    "| 2     | 3      |   |",
    "| 0.0   | 5      |   |",
    "#+TBLFM: $3=$1/$2 :: @6$3=$1+$2 :: @7$3=$1*1 :: @8$3=$1*1",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  local want = {
    "0.33333333",
    "9.765625e-4",
    "0.5",
    "2.",
    "2",
    "0.3",
    "100000000000.",
    "1e12",
    "0.033333333",
    "3.3333333e-3",
    "-9.765625e-4",
    "0.66666667",
    "0.",
  }
  for i, w in ipairs(want) do
    assert_eq(cells(lines[i])[3], w, "line " .. i)
  end
end

-- `%` is Calc's floor modulo: the result takes the divisor's sign.
do
  local b = mk_buf({
    "| -7   | 3  |   |",
    "| -7.0 | 3  |   |",
    "| 7    | -3 |   |",
    "| -7   | -3 |   |",
    "| -7.5 | 2  |   |",
    "#+TBLFM: $3=$1 % $2",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  local want = { "2", "2.", "-2", "-1", "0.5" }
  for i, w in ipairs(want) do
    assert_eq(cells(lines[i])[3], w, "line " .. i)
  end
end

-- Exact bignum results are written in full.
do
  local b = mk_buf({
    "| 2 | 100 |   |",
    "#+TBLFM: $3=$1^$2",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  assert_eq(cells(get_lines(b)[1])[3], "1267650600228229401496703205376")
end

-- A formula that does not parse writes #ERROR into each of its target
-- cells; the other formulas still apply (Emacs `org-table-recalculate`).
do
  local b = mk_buf({ "| 1 |   |", "#+TBLFM: $2=1.2.3" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  local ok, ret = pcall(tab.eval_formulas, b)
  assert(ok, "eval_formulas must not throw: " .. tostring(ret))
  assert_eq(ret, true, "malformed number still recalculates")
  assert_eq(get_lines(b)[1], "| 1 | #ERROR |")

  b = mk_buf({
    "| 1 |   |   |   |",
    "| 2 |   |   |   |",
    "#+TBLFM: $2=$1*2 :: $3=1.2.3 :: $4=$1+1",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  local lines = get_lines(b)
  assert_eq(lines[1], "| 1 | 2 | #ERROR | 2 |")
  assert_eq(lines[2], "| 2 | 4 | #ERROR | 3 |")

  b = mk_buf({ "| 1 |   |", "#+TBLFM: $2=$1+" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  assert_eq(get_lines(b)[1], "| 1 | #ERROR |")
end

-- An unknown LHS is a formula error: reported, table untouched (Emacs
-- `Unknown field`).
do
  local b = mk_buf({ "| 1 |   |   |", "#+TBLFM: $x=1 :: $3=$1+1" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  local ok, ret = pcall(tab.eval_formulas, b)
  assert(ok, "eval_formulas must not throw: " .. tostring(ret))
  assert_eq(ret, false)
  assert_eq(get_lines(b)[1], "| 1 |   |   |", "table untouched")
end

-- An unknown function stays symbolic with its arguments evaluated
-- (Calc): `foo($1)` renders as `foo(1)`.
do
  local b = mk_buf({ "| 1 |   |", "| 2 |   |", "#+TBLFM: $2=foo($1)" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  local ok, ret = pcall(tab.eval_formulas, b)
  assert(ok, "eval_formulas must not throw: " .. tostring(ret))
  assert_eq(ret, true)
  local lines = get_lines(b)
  assert_eq(cells(lines[1])[2], "foo(1)")
  assert_eq(cells(lines[2])[2], "foo(2)")

  b = mk_buf({ "| 1 | 2 |   |   |", "#+TBLFM: $3=foo($1, $2+1) :: $4=bar(foo($1), 1.5)" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  tab.eval_formulas(b)
  lines = get_lines(b)
  assert_eq(cells(lines[1])[3], "foo(1, 3)")
  assert_eq(cells(lines[1])[4], "bar(foo(1), 1.5)")
end

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
