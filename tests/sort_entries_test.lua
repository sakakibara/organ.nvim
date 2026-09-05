-- organ.sort: `:Org sort_entries` (Emacs org-sort-entries, C-c ^).
-- Every expectation below is the buffer real Emacs 30 / org 9.7.11
-- produces for the same input, checked with
--   emacs --batch -Q -l org --eval '(org-sort-entries nil ?<key>)'
-- before it was encoded here.
--
-- Run via: nvim --headless -l tests/sort_entries_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local sort = require("organ.sort")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function sorted(label, lines, line, opts, want)
  local b = mkbuf(lines)
  local n, why = sort.entries(b, line, opts)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(label, n ~= nil and vim.deep_equal(got, want), why or table.concat(got, " | "))
end

local function refused(label, lines, line, opts, want_reason)
  local b = mkbuf(lines)
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local n, why = sort.entries(b, line, opts)
  local after = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(label, n == nil and why == want_reason and vim.deep_equal(before, after), tostring(why))
end

-- 1. Children of the headline at point, alphabetically.
sorted(
  "alpha sorts the children of the entry at point",
  { "* Parent", "** charlie", "** alpha", "** bravo", "* Next" },
  1,
  { key = "a" },
  { "* Parent", "** alpha", "** bravo", "** charlie", "* Next" }
)

-- 2. Before the first headline: the file's top-level entries, each
-- carrying its body.  The preamble stays put.
sorted(
  "before the first heading, top-level entries sort",
  { "preamble", "* charlie", "body c", "* alpha", "body a", "* bravo" },
  1,
  { key = "a" },
  { "preamble", "* alpha", "body a", "* bravo", "* charlie", "body c" }
)

-- 3. Emacs refuses when the entry at point has no children.
refused(
  "an entry with no children refuses",
  { "* Only", "some body" },
  1,
  { key = "a" },
  "nothing to sort"
)

-- 4. The alpha key ignores the TODO keyword, the priority cookie and
-- the tags: `10 charlie` < `2 alpha` < `33 bravo` as plain strings.
local COOKIES = {
  "* P",
  "** TODO [#B] 10 charlie",
  "** DONE [#A] 2 alpha",
  "** [#C] 33 bravo",
}
sorted("alpha strips todo / priority", COOKIES, 1, { key = "a" }, {
  "* P",
  "** TODO [#B] 10 charlie",
  "** DONE [#A] 2 alpha",
  "** [#C] 33 bravo",
})
sorted("numeric reads the leading number", COOKIES, 1, { key = "n" }, {
  "* P",
  "** DONE [#A] 2 alpha",
  "** TODO [#B] 10 charlie",
  "** [#C] 33 bravo",
})
-- Emacs: an active keyword sorts first, no keyword next, DONE last.
sorted("todo order puts active first and DONE last", COOKIES, 1, { key = "o" }, {
  "* P",
  "** TODO [#B] 10 charlie",
  "** [#C] 33 bravo",
  "** DONE [#A] 2 alpha",
})
-- Emacs: a cookie-less entry sorts at org-priority-default (B).
sorted("priority sorts A before B before C", COOKIES, 1, { key = "p" }, {
  "* P",
  "** DONE [#A] 2 alpha",
  "** TODO [#B] 10 charlie",
  "** [#C] 33 bravo",
})

-- 5. Reverse (the capital letter) is a stable DESCENDING sort: ties
-- keep buffer order, exactly as `sort-subr` leaves them.
sorted("uppercase reverses the numeric order", COOKIES, 1, { key = "N" }, {
  "* P",
  "** [#C] 33 bravo",
  "** TODO [#B] 10 charlie",
  "** DONE [#A] 2 alpha",
})

-- 6. Case folding, and the stability that goes with it.
local CASE = { "* P", "** banana", "** Apple", "** apple", "** Banana" }
sorted("alpha folds case and keeps ties in buffer order", CASE, 1, { key = "a" }, {
  "* P",
  "** Apple",
  "** apple",
  "** banana",
  "** Banana",
})
sorted("with_case compares case-sensitively", CASE, 1, { key = "a", with_case = true }, {
  "* P",
  "** Apple",
  "** Banana",
  "** apple",
  "** banana",
})
sorted("reversed ties still read in buffer order", CASE, 1, { key = "A" }, {
  "* P",
  "** banana",
  "** Banana",
  "** Apple",
  "** apple",
})

-- 7. Planning and timestamp keys.  A missing stamp sorts as "now",
-- so it lands after past dates -- Emacs's own fallback.
sorted(
  "scheduled sorts by SCHEDULED date",
  {
    "* P",
    "** c",
    "SCHEDULED: <2026-03-05 Thu>",
    "** a",
    "SCHEDULED: <2026-01-05 Mon>",
    "** b",
    "SCHEDULED: <2026-02-05 Thu>",
  },
  1,
  { key = "s" },
  {
    "* P",
    "** a",
    "SCHEDULED: <2026-01-05 Mon>",
    "** b",
    "SCHEDULED: <2026-02-05 Thu>",
    "** c",
    "SCHEDULED: <2026-03-05 Thu>",
  }
)
sorted(
  "an entry with no deadline sorts as now",
  {
    "* P",
    "** c",
    "DEADLINE: <2026-03-05 Thu>",
    "** a",
    "DEADLINE: <2026-01-05 Mon>",
    "** b",
  },
  1,
  { key = "d" },
  {
    "* P",
    "** a",
    "DEADLINE: <2026-01-05 Mon>",
    "** c",
    "DEADLINE: <2026-03-05 Thu>",
    "** b",
  }
)
sorted(
  "timestamp falls back to an inactive stamp",
  {
    "* P",
    "** c",
    "<2026-03-05 Thu>",
    "** a",
    "[2026-01-05 Mon]",
    "** b",
    "<2026-02-05 Thu>",
  },
  1,
  { key = "t" },
  {
    "* P",
    "** a",
    "[2026-01-05 Mon]",
    "** b",
    "<2026-02-05 Thu>",
    "** c",
    "<2026-03-05 Thu>",
  }
)

-- 8. Property key: a missing property is "", which sorts first.
sorted(
  "property sorts by value, missing first",
  {
    "* P",
    "** c",
    ":PROPERTIES:",
    ":X: zeta",
    ":END:",
    "** a",
    ":PROPERTIES:",
    ":X: alpha",
    ":END:",
    "** b",
  },
  1,
  { key = "r", property = "X" },
  {
    "* P",
    "** b",
    "** a",
    ":PROPERTIES:",
    ":X: alpha",
    ":END:",
    "** c",
    ":PROPERTIES:",
    ":X: zeta",
    ":END:",
  }
)
refused(
  "property without a name refuses",
  { "* P", "** a", "** b" },
  1,
  { key = "r" },
  "sorting by property needs a property name"
)

-- 9. Clocking time: minutes summed from the CLOCK lines, no clock = 0.
sorted(
  "clocking sorts by summed CLOCK minutes",
  {
    "* P",
    "** c",
    ":LOGBOOK:",
    "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00",
    ":END:",
    "** a",
    ":LOGBOOK:",
    "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 13:00] =>  3:00",
    ":END:",
    "** b",
  },
  1,
  { key = "k" },
  {
    "* P",
    "** b",
    "** c",
    ":LOGBOOK:",
    "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00",
    ":END:",
    "** a",
    ":LOGBOOK:",
    "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 13:00] =>  3:00",
    ":END:",
  }
)

-- 10. The parent's own body, drawer and planning stay above the first
-- child; each child keeps its trailing text.
sorted(
  "the parent's body stays put",
  {
    "* P",
    ":PROPERTIES:",
    ":ID: x",
    ":END:",
    "parent body",
    "** c",
    "** a",
    "** b",
    "tail of b",
    "* After",
  },
  1,
  { key = "a" },
  {
    "* P",
    ":PROPERTIES:",
    ":ID: x",
    ":END:",
    "parent body",
    "** a",
    "** b",
    "tail of b",
    "** c",
    "* After",
  }
)

-- 11. An explicit range sorts the entries it covers and extends past
-- the last selected subtree; the rest of the file is untouched.
sorted(
  "a range sorts only its own entries",
  { "* charlie", "cbody", "* alpha", "* bravo", "* zulu" },
  1,
  { key = "a", line1 = 1, line2 = 4 },
  { "* alpha", "* bravo", "* charlie", "cbody", "* zulu" }
)
refused(
  "a range holding a shallower heading refuses",
  { "** deep", "* shallow" },
  1,
  { key = "a", line1 = 1, line2 = 2 },
  "region to sort contains a level above the first entry"
)

-- 12. Unknown keys refuse without touching the buffer.
refused(
  "an unknown key refuses",
  { "* P", "** a", "** b" },
  1,
  { key = "zzz" },
  "invalid sorting type: zzz"
)

-- 13. A user key function, with its own comparator.
do
  local b = mkbuf({ "* P", "** aaa", "** a", "** aa" })
  local n = sort.entries(b, 1, {
    key = "func",
    getkey = function(s)
      return #(vim.api.nvim_buf_get_lines(b, s - 1, s, false)[1] or "")
    end,
    compare = function(x, y)
      return x < y
    end,
  })
  check(
    "func sorts by a caller-supplied key",
    n == 3
      and vim.deep_equal(
        vim.api.nvim_buf_get_lines(b, 0, -1, false),
        { "* P", "** a", "** aa", "** aaa" }
      )
  )
end

-- 14. A wide flat outline sorts in bounded time -- the record walk must
-- stay linear, not quadratic, and must not spin.
do
  local lines = { "* P" }
  for i = 1, 2000 do
    lines[#lines + 1] = ("** entry %04d"):format(2001 - i)
  end
  local b = mkbuf(lines)
  local started = vim.uv.hrtime()
  local n = sort.entries(b, 1, { key = "a" })
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("2000 siblings sort", n == 2000 and got[2] == "** entry 0001", got[2])
  check("2000 siblings sort inside 5s", elapsed < 5000, ("%.0fms"):format(elapsed))
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nsort_entries: all checks passed")
