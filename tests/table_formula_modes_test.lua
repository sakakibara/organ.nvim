-- tests/table_formula_modes_test.lua
-- Run via: nvim --headless -l tests/table_formula_modes_test.lua
--
-- Trailing `;` modes, hline row ranges and exponent literals -- everyday
-- org that organ used to answer with #ERROR, destroying whatever the
-- field held.  Expected values are Emacs's, taken from
--   emacs --batch -Q -l org --eval '(org-table-recalculate t)'
-- over the same table.  Whatever organ still refuses must leave every
-- field byte-for-byte as the user wrote it.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local FIXTURE = {
  "| item | qty | price | total |",
  "|------+-----+-------+-------|",
  "| pen  |   3 |     2 |       |",
  "| pad  |   5 |   1.5 |       |",
  "|------+-----+-------+-------|",
  "| sum  |     |       |       |",
}

local function mk_buf(tblfm)
  local lines = vim.list_slice(FIXTURE, 1, #FIXTURE)
  lines[#lines + 1] = "#+TBLFM: " .. tblfm
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 3, 1 })
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

local function assert_table(tblfm, expected)
  local b = mk_buf(tblfm)
  assert(tab.eval_formulas(b), tblfm .. ": expected the formula to be applied")
  local lines = get_lines(b)
  for i, want in ipairs(expected) do
    assert_eq(lines[i], want, tblfm .. " line " .. i .. ":")
  end
end

-- A printf format renders the result and reads a field it cannot make a
-- number of as 0.
assert_table("$4=$2*$3;%.2f", {
  "| item | qty | price | total |",
  "|------+-----+-------+-------|",
  "| pen  |   3 |     2 |  6.00 |",
  "| pad  |   5 |   1.5 |  7.50 |",
  "|------+-----+-------+-------|",
  "| sum  |     |       |  0.00 |",
})

-- `;N` reads every field as a number, empty ones included.
assert_table("$4=$2+$3;N", {
  "| item | qty | price | total |",
  "|------+-----+-------+-------|",
  "| pen  |   3 |     2 |     5 |",
  "| pad  |   5 |   1.5 |   6.5 |",
  "|------+-----+-------+-------|",
  "| sum  |     |       |     0 |",
})

-- `@I..@II` spans the rows between the first and second hline.
assert_table("@4$2=vsum(@I$2..@II$2)", {
  "| item | qty | price | total |",
  "|------+-----+-------+-------|",
  "| pen  |   3 |     2 |       |",
  "| pad  |   5 |   1.5 |       |",
  "|------+-----+-------+-------|",
  "| sum  |   8 |       |       |",
})

-- Exponent literals tokenise, and a mode plus an hline range coexist
-- across two `::`-separated formulas.
assert_table("$4=1e12", {
  "| item | qty | price | total |",
  "|------+-----+-------+-------|",
  "| pen  |   3 |     2 |  1e12 |",
  "| pad  |   5 |   1.5 |  1e12 |",
  "|------+-----+-------+-------|",
  "| sum  |     |       |  1e12 |",
})

assert_table("$4=$2*$3;%.2f::@4$4=vsum(@I$4..@II$4)", {
  "| item | qty | price | total |",
  "|------+-----+-------+-------|",
  "| pen  |   3 |     2 |  6.00 |",
  "| pad  |   5 |   1.5 |  7.50 |",
  "|------+-----+-------+-------|",
  "| sum  |     |       |  13.5 |",
})

-- Refused: valid org organ has not implemented.  Emacs aborts the
-- recalculation on each of these too, and in every case the fields the
-- user typed have to come back untouched -- never #ERROR.
local REFUSED = {
  "$4=$2+$3;R",
  "$4=$2+$3;E",
  "$4=$2+$3;f3",
  "$4=remote(other,@1$1)",
  "$4=@-I$2",
  "@-1$1=$2",
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

-- A genuinely malformed right-hand side still writes #ERROR, as org does.
do
  local b = mk_buf("$4=$2+")
  assert(tab.eval_formulas(b), "malformed RHS still recalculates")
  local lines = get_lines(b)
  assert(lines[3]:find("#ERROR", 1, true), "malformed RHS writes #ERROR, got: " .. lines[3])
end

io.write("table formula modes ok\n")
