-- tests/table_formula_precedence_test.lua
-- Run via: nvim --headless -l tests/table_formula_precedence_test.lua
--
-- Calc's operator table binds `*` tighter than `/` and `%`, so a
-- division's denominator swallows the multiplications that follow it:
-- `a/b*c` is `a/(b*c)` while `a*b/c` stays `(a*b)/c`.  Expected values
-- are Emacs's, taken from
--   emacs --batch -Q -l org --eval '(org-table-recalculate t)'
-- over the same table, down to the spelling of the printed field.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local FIXTURE = { "| 1 | 2 |", "| 3 | 4 |" }

local function cells(line)
  local out = {}
  for c in line:gmatch("|([^|]*)") do
    out[#out + 1] = c:match("^%s*(.-)%s*$")
  end
  out[#out] = nil
  return out
end

-- `rhs` is evaluated as a `$3=` column formula; `want` is @1$3.
local function assert_field(rhs, want)
  local lines = vim.list_slice(FIXTURE, 1, #FIXTURE)
  lines[#lines + 1] = "#+TBLFM: $3=" .. rhs
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  assert(tab.eval_formulas(b), rhs .. ": expected the formula to be applied")
  local got = cells(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1])[3]
  if got ~= want then
    error("$3=" .. rhs .. ": expected " .. tostring(want) .. " got " .. tostring(got))
  end
end

-- A division's denominator absorbs the multiplication chain after it;
-- a division after a product does not reach back into it.
assert_field("8/2*4", "1")
assert_field("2*8/2", "8")
assert_field("1*2/4", "0.5")
assert_field("2*3/4*2", "0.75")
assert_field("64/2*4*2", "4")
assert_field("8/(2*4)", "1")
assert_field("(64/2)*4", "128")
assert_field("64/(2)*4", "8")

-- Division and mod share one left-associative level below `*`.
assert_field("8/2/2", "2")
assert_field("64/2*4/2", "4")
assert_field("64/2/4*2", "4")
assert_field("1/2/2*2", "0.125")
assert_field("8/2*4/2*2", "0.25")
assert_field("6*4/3/2*2", "2")
assert_field("12%5*2", "2")
assert_field("100/10%3", "1")
assert_field("8%3*2%3", "2")

-- Addition stays below both, and `^` above both.
assert_field("1+2*3", "7")
assert_field("8/2-1", "3")
assert_field("100/2*5+1", "11")
assert_field("1+64/2*4", "9")
assert_field("8/2*4-1", "0")
assert_field("2^3*2", "16")
assert_field("8/2^2", "2")
assert_field("64/2^2*2", "8")
assert_field("64/2*4^2", "2")
assert_field("2^3^2", "512")

-- Unary minus binds tighter than `*`, `/` and `%`, looser than `^`.
assert_field("-2^2", "-4")
assert_field("2^-3", "0.125")
assert_field("-64/2*4", "-8")
assert_field("8/2*-4", "-1")
assert_field("-8/-2*4", "1")
assert_field("-8%3", "1")

-- References, calls and floats parse through the same levels.
assert_field("$1/$2*4", "0.125")
assert_field("@1$1/2*4", "0.125")
assert_field("vsum($1..$2)/2*4", "0.375")
assert_field("64/vsum($1..$2)*2", "10.666667")
assert_field("0.5/0.25*2", "1.")
assert_field("1e2/2*5", "10.")

io.write("table formula precedence ok\n")
