-- tests/table_formula_target_test.lua
-- Run via: nvim --headless -l tests/table_formula_target_test.lua
--
-- Row / column descriptors on a formula's left-hand side: `@>$1=`,
-- `$>=`, `@<<$>>=` and the rest.  Expected values are Emacs's, taken
-- from
--   emacs --batch -Q -l org --eval '(org-table-recalculate t)'
-- over the same table.  A target Emacs refuses to assign to has to
-- leave every field byte-for-byte as the user wrote it.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local FIXTURE = {
  "| 1 | 2 | 5 |",
  "| 3 | 4 | 6 |",
  "|---+---+---|",
  "|   |   |   |",
  "|   |   |   |",
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

-- `grid` is the whole table as Emacs leaves it, data rows only (the
-- hline on line 3 keeps its place).
local function assert_grid(tblfm, grid)
  local b = mk_buf(tblfm)
  assert(tab.eval_formulas(b), tblfm .. ": expected the formula to be applied")
  local lines = get_lines(b)
  local rows = { 1, 2, 4, 5 }
  for i, want in ipairs(grid) do
    assert_eq(
      table.concat(cells(lines[rows[i]]), "/"),
      table.concat(want, "/"),
      tblfm .. " data row " .. i .. ":"
    )
  end
end

-- Row descriptors.  `@N` counts data rows, so `@>` is buffer line 5 and
-- `@>>` line 4.
assert_grid("@>$1=1", { { "1", "2", "5" }, { "3", "4", "6" }, { "", "", "" }, { "1", "", "" } })
assert_grid("@<$1=2", { { "2", "2", "5" }, { "3", "4", "6" }, { "", "", "" }, { "", "", "" } })
assert_grid("@>>$1=3", { { "1", "2", "5" }, { "3", "4", "6" }, { "3", "", "" }, { "", "", "" } })
assert_grid("@<<$1=4", { { "1", "2", "5" }, { "4", "4", "6" }, { "", "", "" }, { "", "", "" } })

-- Column descriptors.  A column formula starts below the first hline.
assert_grid("$>=9", { { "1", "2", "5" }, { "3", "4", "6" }, { "", "", "9" }, { "", "", "9" } })
assert_grid("$<=8", { { "1", "2", "5" }, { "3", "4", "6" }, { "8", "", "" }, { "8", "", "" } })
assert_grid("$>>=7", { { "1", "2", "5" }, { "3", "4", "6" }, { "", "7", "" }, { "", "7", "" } })

-- Both axes at once.
assert_grid("@2$>=99", { { "1", "2", "5" }, { "3", "4", "99" }, { "", "", "" }, { "", "", "" } })
assert_grid("@<$>=77", { { "1", "2", "77" }, { "3", "4", "6" }, { "", "", "" }, { "", "", "" } })
assert_grid("@>$<=88", { { "1", "2", "5" }, { "3", "4", "6" }, { "", "", "" }, { "88", "", "" } })
assert_grid("@>>$>>=11", { { "1", "2", "5" }, { "3", "4", "6" }, { "", "11", "" }, { "", "", "" } })

-- A row formula takes a descriptor too.
assert_grid("@>=42", { { "1", "2", "5" }, { "3", "4", "6" }, { "", "", "" }, { "42", "42", "42" } })

-- The everyday total-row idiom: an aggregate over an hline-delimited
-- block, written into the bottom row.
assert_grid(
  "@>$1=vsum(@I$1..@II$1)",
  { { "1", "2", "5" }, { "3", "4", "6" }, { "", "", "" }, { "0", "", "" } }
)

-- Targets Emacs declines: an hline relative reference, a row offset,
-- `@#` / `$#`, and anything resolving outside the table.  Every one of
-- them leaves the table byte-unchanged.
local REFUSED = {
  "@I$1=11",
  "@II$1=12",
  "@-1$1=5",
  "@#$1=5",
  "$#=5",
  "@9$1=13",
  "@0$1=1",
  "@>>>>>$1=1",
  "@<<<<<$1=1",
  "$>>>>=1",
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

io.write("table formula target ok\n")
