-- Comprehensive coverage of bracketed skip filters on repeaters.
-- Run via: nvim --headless -l tests/todo_repeater_filter_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local rep = require("organ.todo.repeater")

local function eq(actual, expected, label)
  if actual ~= expected then
    error(label .. ":\n  expected: " .. tostring(expected) .. "\n  actual:   " .. tostring(actual))
  end
end

local function ok(text, base, expected, label)
  local got = rep.bump(text, base)
  eq(got, expected, label)
end

-- ──────────────────────────────────────────────────────────────────
-- Existing baseline (kept here too so this file stands alone).
-- ──────────────────────────────────────────────────────────────────

ok("<2026-04-25 Sat +1d[wd]>", "2026-04-25", "<2026-04-27 Mon +1d[wd]>", "[wd] skips weekend")

ok("<2026-04-26 Sun +1d[we]>", "2026-04-26", "<2026-05-02 Sat +1d[we]>", "[we] lands on next Sat")

ok(
  "<2026-04-26 Sun +1d[mon,wed,fri]>",
  "2026-04-26",
  "<2026-04-27 Mon +1d[mon,wed,fri]>",
  "[mon,wed,fri] OR-combined named days"
)

ok("<2026-04-25 Fri +1d[!sat]>", "2026-04-25", "<2026-04-26 Sun +1d[!sat]>", "[!sat] skips Sat")

-- ──────────────────────────────────────────────────────────────────
-- dom:N — exact day of month
-- ──────────────────────────────────────────────────────────────────

ok(
  "<2026-04-01 Wed +1d[dom:25]>",
  "2026-04-01",
  "<2026-04-25 Sat +1d[dom:25]>",
  "[dom:25] lands on the 25th"
)

ok(
  "<2026-04-10 Fri +1m[dom:25]>",
  "2026-04-10",
  "<2026-05-25 Mon +1m[dom:25]>",
  "+1m[dom:25] forwards a month then snaps to the 25th if needed"
)

ok(
  "<2026-04-01 Wed +1d[dom:1]>",
  "2026-04-01",
  "<2026-05-01 Fri +1d[dom:1]>",
  "[dom:1] lands on the 1st of next month"
)

ok("<2026-04-01 Wed +1d[bom]>", "2026-04-01", "<2026-05-01 Fri +1d[bom]>", "bom alias = dom:1")

-- ──────────────────────────────────────────────────────────────────
-- dom:-N — Nth from end (iCal semantics: -1 = last, -2 = penultimate)
-- ──────────────────────────────────────────────────────────────────

-- April 2026 has 30 days; -1 = 30, -3 = 28.
ok(
  "<2026-04-01 Wed +1d[dom:-1]>",
  "2026-04-01",
  "<2026-04-30 Thu +1d[dom:-1]>",
  "[dom:-1] = last day (April: 30)"
)

ok(
  "<2026-04-01 Wed +1d[dom:-3]>",
  "2026-04-01",
  "<2026-04-28 Tue +1d[dom:-3]>",
  "[dom:-3] = third-to-last (April: 28)"
)

ok("<2026-04-01 Wed +1d[eom]>", "2026-04-01", "<2026-04-30 Thu +1d[eom]>", "eom alias = dom:-1")

-- February 2026 has 28 days; -1 = 28, -3 = 26.
ok(
  "<2026-02-01 Sun +1d[dom:-3]>",
  "2026-02-01",
  "<2026-02-26 Thu +1d[dom:-3]>",
  "[dom:-3] adapts to Feb 28"
)

-- ──────────────────────────────────────────────────────────────────
-- 3 days before last day of month (`dom:-4`) excluding weekends/holidays
-- ──────────────────────────────────────────────────────────────────

-- April 2026: -4 = day 27 (Monday). Should land directly.
ok(
  "<2026-04-01 Wed +1d[dom:-4,wd]>",
  "2026-04-01",
  "<2026-04-27 Mon +1d[dom:-4,wd]>",
  "[dom:-4,wd] = 4th-from-last when it's a weekday"
)

-- A holiday calendar that marks 2026-04-27.
rep._test_calendar = function(name, date)
  if name == "test" then
    return date == "2026-04-27"
  end
  return false
end
-- The 27th is a "holiday" → iterate forward until next dom:-4 weekday non-holiday.
-- Day 27 fails (cal:test). Iterating forward, no more dom:-4 days until next month.
-- May 2026: 31 days, -4 = day 28 (Thu, not holiday) → match.
ok(
  "<2026-04-01 Wed +1d[dom:-4,wd,!cal:test]>",
  "2026-04-01",
  "<2026-05-28 Thu +1d[dom:-4,wd,!cal:test]>",
  "[dom:-4,wd,!cal:test] skips holiday on -4 day"
)
rep._test_calendar = nil

-- ──────────────────────────────────────────────────────────────────
-- nth:K:DOW — Kth weekday of the month
-- ──────────────────────────────────────────────────────────────────

-- April 2026: 1st Mon = 4-06; 2nd Mon = 4-13; 3rd Mon = 4-20; last Mon = 4-27.
ok(
  "<2026-04-01 Wed +1d[nth:1:mon]>",
  "2026-04-01",
  "<2026-04-06 Mon +1d[nth:1:mon]>",
  "[nth:1:mon] = first Monday of month"
)

ok(
  "<2026-04-01 Wed +1d[nth:2:mon]>",
  "2026-04-01",
  "<2026-04-13 Mon +1d[nth:2:mon]>",
  "[nth:2:mon] = second Monday of month"
)

ok(
  "<2026-04-01 Wed +1d[nth:last:fri]>",
  "2026-04-01",
  "<2026-04-24 Fri +1d[nth:last:fri]>",
  "[nth:last:fri] = last Friday of April (24th)"
)

ok(
  "<2026-04-01 Wed +1d[nth:3:fri]>",
  "2026-04-01",
  "<2026-04-17 Fri +1d[nth:3:fri]>",
  "[nth:3:fri] = third Friday"
)

-- nth:K:DOW1;DOW2 — Kth occurrence of any listed weekday (still K must match
-- the chosen DOW, evaluated independently — so this means "Kth Monday OR
-- Kth Tuesday"). Helpful for "first Mon or Tue of month".
ok(
  "<2026-04-01 Wed +1d[nth:1:mon;tue]>",
  "2026-04-01",
  "<2026-04-06 Mon +1d[nth:1:mon;tue]>",
  "[nth:1:mon;tue] picks whichever first-of-month occurs sooner"
)

-- ──────────────────────────────────────────────────────────────────
-- month:N / named months / quarter:Q
-- ──────────────────────────────────────────────────────────────────

-- Only 1st of January each year.
ok(
  "<2026-04-01 Wed +1d[month:1,dom:1]>",
  "2026-04-01",
  "<2027-01-01 Fri +1d[month:1,dom:1]>",
  "[month:1,dom:1] = New Year's Day"
)

ok(
  "<2026-04-01 Wed +1d[jan,dom:1]>",
  "2026-04-01",
  "<2027-01-01 Fri +1d[jan,dom:1]>",
  "[jan,dom:1] = same via named month"
)

-- Quarter starts: 1st of Jan/Apr/Jul/Oct.  Use dom:1 + month:1;4;7;10
-- so the filter is "day-of-month is 1 AND month is one of 1/4/7/10".
ok(
  "<2026-04-01 Wed +1d[month:1;4;7;10,dom:1]>",
  "2026-04-02",
  "<2026-07-01 Wed +1d[month:1;4;7;10,dom:1]>",
  "[month:1;4;7;10,dom:1] = first of each quarter (next from Apr 2 is Jul 1)"
)

-- Same intent via the named-month OR list (jan,apr,jul,oct) plus dom:1.
ok(
  "<2026-04-01 Wed +1d[jan,apr,jul,oct,dom:1]>",
  "2026-04-02",
  "<2026-07-01 Wed +1d[jan,apr,jul,oct,dom:1]>",
  "named-month OR list + dom:1 = same thing"
)

-- quarter:1 (first quarter only) AND dom:1 = 1st of Jan/Feb/Mar.  Starting
-- from Apr 2, the next match is next year's Jan 1.
ok(
  "<2026-04-01 Wed +1d[quarter:1,dom:1]>",
  "2026-04-02",
  "<2027-01-01 Fri +1d[quarter:1,dom:1]>",
  "[quarter:1,dom:1] = 1st of any month in Q1 (next is Jan 2027)"
)

-- ──────────────────────────────────────────────────────────────────
-- bizday — Nth business day with default holiday calendar
-- ──────────────────────────────────────────────────────────────────

-- bizday alone = "any business day".  Equivalent to `wd` if no holiday cal.
ok(
  "<2026-04-25 Sat +1d[bizday]>",
  "2026-04-25",
  "<2026-04-27 Mon +1d[bizday]>",
  "[bizday] alone behaves like [wd] with no holiday cal"
)

-- April 2026: business days are Mon-Fri.  1st bizday = Apr 1 (Wed).
-- April 2026 layout: 1=Wed,2=Thu,3=Fri,(4-5 weekend),6=Mon,7=Tue,...
-- Start mid-month so +1m lands 2026-05-15, then filter forwards to the
-- next 1st business day = June 1 (Mon).
ok(
  "<2026-04-15 Wed +1m[bizday:1]>",
  "2026-04-15",
  "<2026-06-01 Mon +1m[bizday:1]>",
  "[bizday:1] = 1st business day of next eligible month"
)

-- Direct: starting Apr 2, the next 1st-business-day is May 1 (Fri).
ok(
  "<2026-04-01 Wed +1d[bizday:1]>",
  "2026-04-02",
  "<2026-05-01 Fri +1d[bizday:1]>",
  "[bizday:1] = 1st business day of next month (May 1 is Fri)"
)

-- bizday:-1 = last business day of month.  April 2026: 30 = Thu.
ok(
  "<2026-04-01 Wed +1d[bizday:-1]>",
  "2026-04-01",
  "<2026-04-30 Thu +1d[bizday:-1]>",
  "[bizday:-1] = last business day of April (30 Thu)"
)

-- ──────────────────────────────────────────────────────────────────
-- "Just Monday" — single named day
-- ──────────────────────────────────────────────────────────────────

ok("<2026-04-25 Sat +1d[mon]>", "2026-04-25", "<2026-04-27 Mon +1d[mon]>", "[mon] = single Monday")

-- ──────────────────────────────────────────────────────────────────
-- 2nd Monday of month (e.g., U.S. Columbus Day pattern)
-- ──────────────────────────────────────────────────────────────────

ok(
  "<2026-04-01 Wed +1d[nth:2:mon]>",
  "2026-04-01",
  "<2026-04-13 Mon +1d[nth:2:mon]>",
  "[nth:2:mon] = 2nd Monday"
)

-- ──────────────────────────────────────────────────────────────────
-- Impossibility — bounded iteration
-- ──────────────────────────────────────────────────────────────────

local _, err = rep.bump("<2026-04-26 Sun +1d[wd,we]>", "2026-04-26")
assert(err and err:find("impossible"), "expected impossible-filter error, got " .. tostring(err))

io.write("todo repeater filter ok\n")
os.exit(0)
