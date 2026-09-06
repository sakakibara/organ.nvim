-- tests/table_formula_symbolic_test.lua
-- Run via: nvim --headless -l tests/table_formula_symbolic_test.lua
--
-- A field spelled like a name is a symbol, and arithmetic over it stays
-- algebraic instead of writing #ERROR over the user's data.  Expected
-- values are Emacs's, taken from
--   emacs --batch -Q -l org --eval '(org-table-recalculate t)'
-- over the same table, down to the spelling: Calc writes a product as
-- juxtaposition with the coefficient first (`2 h1`), and spells that one
-- product with a `*` where juxtaposition would read as a function call.
-- Whatever organ still refuses must leave every field byte-for-byte as
-- the user wrote it.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local FIXTURE = {
  "| h1 | 2 |  |",
  "| x  | 3 |  |",
}

local function mk_buf(tblfm)
  local lines = vim.list_slice(FIXTURE, 1, #FIXTURE)
  lines[#lines + 1] = "#+TBLFM: " .. tblfm
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
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

-- `want` is $3 in each of the two data rows.
local function assert_third(tblfm, want)
  local b = mk_buf(tblfm)
  assert(tab.eval_formulas(b), tblfm .. ": expected the formula to be applied")
  local lines = get_lines(b)
  for i, w in ipairs(want) do
    assert_eq(cells(lines[i])[3], w, tblfm .. " row " .. i .. ":")
  end
end

-- A bare reference to a text field yields that text.
assert_third("$3=@<$1", { "h1", "h1" })
assert_third("$3=$1", { "h1", "x" })

-- Sums and differences with a number keep the order they were written.
assert_third("$3=$1+4", { "h1 + 4", "x + 4" })
assert_third("$3=4+$1", { "4 + h1", "4 + x" })
assert_third("$3=-2+$1", { "h1 - 2", "x - 2" })
assert_third("$3=$1-4", { "h1 - 4", "x - 4" })
assert_third("$3=4-$1", { "4 - h1", "4 - x" })
assert_third("$3=$1+2.5", { "h1 + 2.5", "x + 2.5" })
assert_third("$3=$1+$2", { "h1 + 2", "x + 3" })

-- A product puts the coefficient first and drops the operator.
assert_third("$3=$1*2", { "2 h1", "2 x" })
assert_third("$3=2*$1", { "2 h1", "2 x" })
assert_third("$3=$1*$2", { "2 h1", "3 x" })
assert_third("$3=$1*2*3", { "6 h1", "6 x" })
assert_third("$3=2*($1+1)", { "2 h1 + 2", "2 x + 2" })

-- Quotients, negation and powers.
assert_third("$3=$1/2", { "h1 / 2", "x / 2" })
assert_third("$3=2/$1", { "2 / h1", "2 / x" })
assert_third("$3=-$1", { "-h1", "-x" })
assert_third("$3=$1^2", { "h1^2", "x^2" })
assert_third("$3=($1+2)/2", { "h1 / 2 + 1", "x / 2 + 1" })

-- Like terms and equal bases collect.
assert_third("$3=$1+$1", { "2 h1", "2 x" })
assert_third("$3=$1-$1", { "0", "0" })
assert_third("$3=$1*$1", { "h1^2", "x^2" })
assert_third("$3=$1/$1", { "1", "1" })
assert_third("$3=1/$1+1/$1", { "2 / h1", "2 / x" })
assert_third("$3=($1+4)*($1+4)", { "(h1 + 4)^2", "(x + 4)^2" })

-- `h1 (h1 + 1)` would read as a function call, so Calc spells this one
-- product with a `*`.
assert_third("$3=$1*($1+1)", { "h1*(h1 + 1)", "x*(x + 1)" })

-- Identities.
assert_third("$3=$1*0", { "0", "0" })
assert_third("$3=$1*1", { "h1", "x" })
assert_third("$3=$1+0", { "h1", "x" })

-- Aggregations that fold with `+` carry a symbol through.
assert_third("$3=vsum($1..$2)", { "h1 + 2", "x + 3" })
assert_third("$3=vmean($1..$2)", { "h1 / 2 + 1", "x / 2 + 1.5" })
assert_third("$3=vlen($1..$2)", { "2", "2" })

-- An unknown function stays symbolic over a symbolic argument.
assert_third("$3=foo($1)", { "foo(h1)", "foo(x)" })

-- Under `;N` every field reads as a number, so a symbol is 0.
assert_third("$3=$1+1;N", { "1", "1" })

-- A printf format reads a result it cannot make a number of as 0.
assert_third("$3=$1+1;%.2f", { "0.00", "0.00" })

-- Refused: symbolic forms organ will not spell.  Emacs answers each of
-- these, organ declines rather than guess, and the fields the user
-- typed come back untouched -- never #ERROR.
local REFUSED = {
  "$3=$1==2",
  "$3=$1<2",
  "$3=if($1>0,1,2)",
  "$3=$1 % 2",
  "$3=mod($1,2)",
  "$3=sqrt($1)",
  "$3=abs($1)",
  "$3=min($1,2)",
  "$3=vmax($1..$2)",
  "$3=vmedian($1..$2)",
  "$3=vproduct($1..$2)",
  "$3=$1+$1/2",
}

for _, tblfm in ipairs(REFUSED) do
  local b = mk_buf(tblfm)
  assert_eq(tab.eval_formulas(b), false, tblfm .. ": expected a refusal")
  local lines = get_lines(b)
  assert_eq(#lines, #FIXTURE + 1, tblfm .. ": line count")
  for i, want in ipairs(FIXTURE) do
    assert_eq(lines[i], want, tblfm .. " line " .. i .. " must be byte-unchanged:")
  end
end

-- A field organ cannot read as a name or a number is still #ERROR, as
-- it is in Emacs when Calc cannot parse the field either.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "| a.b | 2 |  |", "#+TBLFM: $3=$1+1" })
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  assert(tab.eval_formulas(b), "an unreadable field still recalculates")
  assert_eq(cells(get_lines(b)[1])[3], "#ERROR", "unreadable field:")
end

io.write("table formula symbolic ok\n")
