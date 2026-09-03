-- tests/table_formula_parse_test.lua
-- Run via: nvim --headless -l tests/table_formula_parse_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local f = require("organ.table.formula")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- Parse $4=$2*$3 → one col_formula with binop.
do
  local out = f.parse("$4=$2*$3")
  assert_eq(#out, 1)
  assert_eq(out[1].kind, "col_formula")
  assert_eq(out[1].col, 4)
  local e = out[1].expr
  assert_eq(e.kind, "binop")
  assert_eq(e.op, "*")
  assert_eq(e.left.kind, "ref")
  assert_eq(e.left.col, 2)
  assert_eq(e.right.kind, "ref")
  assert_eq(e.right.col, 3)
end

-- Parse @5$4=vsum($1..$3) → cell_formula with call(vsum, range).
do
  local out = f.parse("@5$4=vsum($1..$3)")
  assert_eq(#out, 1)
  assert_eq(out[1].kind, "cell_formula")
  assert_eq(out[1].row, 5)
  assert_eq(out[1].col, 4)
  local e = out[1].expr
  assert_eq(e.kind, "call")
  assert_eq(e.name, "vsum")
  assert_eq(e.arg.kind, "range")
  assert_eq(e.arg.from.col, 1)
  assert_eq(e.arg.to.col, 3)
end

-- Parse $1=1 :: $2=2 → two formulas.
do
  local out = f.parse("$1=1 :: $2=2")
  assert_eq(#out, 2)
  assert_eq(out[1].col, 1)
  assert_eq(out[2].col, 2)
end

-- Parse range @2$4..@5$4.
do
  local out2 = f.parse("$1=vsum(@2$4..@5$4)")
  local rng = out2[1].expr.arg
  assert_eq(rng.kind, "range")
  assert_eq(rng.from.row, 2)
  assert_eq(rng.from.col, 4)
  assert_eq(rng.to.row, 5)
  assert_eq(rng.to.col, 4)
end

-- Parse error in the RHS: the formula keeps its target and carries an
-- error node so evaluation writes #ERROR into it.
do
  local out = f.parse("$1=vsum($2..$3 :: $2=1.2.3 :: $3=@1$1")
  assert_eq(#out, 3)
  assert_eq(out[1].kind, "col_formula")
  assert_eq(out[1].col, 1)
  assert_eq(out[1].expr.kind, "error")
  assert(
    out[1].expr.message:find("paren") or out[1].expr.message:find("rparen"),
    "error mentions parens, got: " .. tostring(out[1].expr.message)
  )
  assert_eq(out[2].expr.kind, "error")
  assert(out[2].expr.message:find("malformed number"), out[2].expr.message)
  assert_eq(out[3].expr.kind, "ref")
end

-- Parse error in the LHS raises.
do
  local ok, err = pcall(f.parse, "$x=1 :: $3=1")
  assert(not ok, "should error")
  assert(tostring(err):find("LHS"), "error mentions LHS, got: " .. tostring(err))
end

-- Parse @4=42 → row_formula.
do
  local out = f.parse("@4=42")
  assert_eq(out[1].kind, "row_formula")
  assert_eq(out[1].row, 4)
  assert_eq(out[1].expr.kind, "num")
  assert_eq(out[1].expr.value, 42)
end

io.write("table formula parse ok\n")
