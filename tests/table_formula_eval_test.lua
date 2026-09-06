-- tests/table_formula_eval_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local f = require("organ.table.formula")

local function rows_from(grid)
  local rows = {}
  for _, line in ipairs(grid) do
    rows[#rows + 1] = { cells = line, sep = false }
  end
  return rows
end

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- Eval $2 * $3 in a row.
do
  local rows = rows_from({ { "", "3", "4", "" } })
  local ast = f.parse("$4=$2*$3")[1].expr
  local v = f.eval(ast, { rows = rows, current_row = 1, current_col = 4 })
  assert_eq(v, 12)
end

-- Eval vsum($2..$3).
do
  local rows = rows_from({ { "", "3", "4", "" } })
  local ast = f.parse("$1=vsum($2..$3)")[1].expr
  local v = f.eval(ast, { rows = rows, current_row = 1, current_col = 1 })
  assert_eq(v, 7)
end

-- Division by zero keeps the quotient standing, as Calc does.
do
  local rows = rows_from({ { "1", "0" } })
  local ast = f.parse("$3=$1/$2")[1].expr
  local v = f.eval(ast, { rows = rows, current_row = 1, current_col = 3 })
  assert_eq(f.format_value(v), "1/0")
end

-- Empty cell ref returns nil.
do
  local rows = rows_from({ { "1", "" } })
  local ast = f.parse("$3=$2")[1].expr
  local v = f.eval(ast, { rows = rows, current_row = 1, current_col = 3 })
  assert_eq(v, nil)
end

-- vmean over a column.
do
  local rows = rows_from({ { "10" }, { "20" }, { "30" } })
  local ast = f.parse("$2=vmean(@1$1..@3$1)")[1].expr
  local v = f.eval(ast, { rows = rows, current_row = 1, current_col = 2 })
  assert_eq(v, 20)
end

-- vmax / vmin / vlen.
do
  local rows = rows_from({ { "1" }, { "5" }, { "" }, { "3" } })
  local ctx = { rows = rows, current_row = 1, current_col = 2 }
  assert_eq(f.eval(f.parse("$2=vmax(@1$1..@4$1)")[1].expr, ctx), 5)
  assert_eq(f.eval(f.parse("$2=vmin(@1$1..@4$1)")[1].expr, ctx), 1)
  assert_eq(f.eval(f.parse("$2=vlen(@1$1..@4$1)")[1].expr, ctx), 3)
end

io.write("table formula eval ok\n")
