-- Table alignment via `:Org format` (whole buffer), `:Org format <range>`,
-- `formatexpr` (`gq`), and tablature's own `realign` must all produce the
-- IDENTICAL buffer state.  All four entry points go through tablature's
-- alignment math via organ.table.realign; the contract is that no entry
-- point produces a different result from any other.
--
-- Run via: nvim --headless -l tests/format_table_consistency_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

-- A deliberately-misaligned org table.  Each entry point should
-- normalize this to the same aligned form tablature produces.
local INPUT = {
  "* Heading",
  "",
  "Some prose paragraph here.",
  "",
  "|name|qty |total|",
  "|----+----+-----|",
  "|apple|  1|  100|",
  "| banana |2|200|",
  "|cherry|33| 9999|",
  "",
  "Trailing prose.",
}

local fmt = require("organ.format")
local table_mod = require("organ.table")

local function fresh_buf()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, INPUT)
  vim.bo[b].filetype = "org"
  return b
end

local function get_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function table_lines(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if l:match("^%s*|") then
      out[#out + 1] = l
    end
  end
  return out
end

local function show(label, lines)
  print("---- " .. label .. " ----")
  for i, l in ipairs(lines) do
    print(string.format("%2d  %q", i, l))
  end
end

-- Reference: tablature.realign at the table's first row.
local b_ref = fresh_buf()
local table_first_lnum
for i, l in ipairs(INPUT) do
  if l:match("^%s*|") then
    table_first_lnum = i
    break
  end
end
assert(table_first_lnum, "fixture has at least one table row")
table_mod.realign(b_ref, table_first_lnum)
local ref_lines = table_lines(get_lines(b_ref))

-- Entry point 1: format_buffer (whole-buffer `:Org format`)
local b1 = fresh_buf()
fmt.format_buffer(b1)
local lines1 = table_lines(get_lines(b1))

-- Entry point 2: format_range over the table only (`:N,M Org format`)
local b2 = fresh_buf()
fmt.format_range(b2, table_first_lnum, table_first_lnum + 4)
local lines2 = table_lines(get_lines(b2))

-- Entry point 3: simulate formatexpr (gq) by invoking format_range
-- over the table region the way `v:lnum + v:count - 1` would.
local b3 = fresh_buf()
fmt.format_range(b3, table_first_lnum, table_first_lnum + 4)
local lines3 = table_lines(get_lines(b3))

-- Entry point 4: format_range over a prose-only range (does NOT
-- intersect the table) -- the table is left alone, NOT realigned.
-- `gq` on a paragraph shouldn't touch unrelated tables in the buffer.
local b4 = fresh_buf()
fmt.format_range(b4, 3, 3)
local untouched_table = table_lines(get_lines(b4))

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function same(label, got, want)
  if #got ~= #want then
    show("got", got)
    show("want", want)
    check(label, false, ("row count differs: got %d, want %d"):format(#got, #want))
    return
  end
  for i = 1, #got do
    if got[i] ~= want[i] then
      show("got", got)
      show("want", want)
      check(
        label,
        false,
        ("row %d differs:\n     got  %q\n     want %q"):format(i, got[i], want[i])
      )
      return
    end
  end
  check(label, true)
end

same("format_buffer matches tablature.realign", lines1, ref_lines)
same("format_range over table matches tablature.realign", lines2, ref_lines)
same("formatexpr-style range matches tablature.realign", lines3, ref_lines)
-- Negative case: prose-only range leaves the table alone (matches the
-- input verbatim), so a `gq` on a paragraph never silently rewrites
-- an unrelated table elsewhere in the buffer.
same("range outside any table leaves the table verbatim", untouched_table, table_lines(INPUT))

-- Independence: realign must be idempotent.  Running format twice
-- shouldn't change anything (otherwise format-on-save would dirty
-- the buffer on every save).
local b_idempotent = fresh_buf()
fmt.format_buffer(b_idempotent)
local first = get_lines(b_idempotent)
fmt.format_buffer(b_idempotent)
local second = get_lines(b_idempotent)
local idempotent = (#first == #second)
if idempotent then
  for i = 1, #first do
    if first[i] ~= second[i] then
      idempotent = false
      break
    end
  end
end
check("format_buffer is idempotent", idempotent)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_table_consistency_test: PASS")
