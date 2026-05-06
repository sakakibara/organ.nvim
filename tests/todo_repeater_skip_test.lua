-- Bracketed skip filters on repeaters.
-- Run via: nvim --headless -l tests/todo_repeater_skip_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local rep = require("organ.todo.repeater")

local function eq(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

-- parse extracts filter
local p = rep.parse("<2026-04-26 Sun +1d[wd]>")
assert(p and p.filter == "wd", "parse [wd]")
local p2 = rep.parse("<2026-04-26 Sun +1d[mon,wed,fri]>")
assert(p2 and p2.filter == "mon,wed,fri", "parse multi-token")

-- bump with [wd]: skip Sat/Sun
-- 2026-04-25 Sat → +1d → 2026-04-26 Sun → skip → 2026-04-27 Mon
eq(
  rep.bump("<2026-04-25 Sat +1d[wd]>", "2026-04-25"),
  "<2026-04-27 Mon +1d[wd]>",
  "+1d[wd] from Sat skips Sun"
)

-- bump with [we]: only weekends
-- 2026-04-26 Sun (today) +1d = Mon → skip → ... → Sat
eq(
  rep.bump("<2026-04-26 Sun +1d[we]>", "2026-04-26"),
  "<2026-05-02 Sat +1d[we]>",
  "+1d[we] lands on next Sat"
)

-- bump with [mon,wed,fri]
-- 2026-04-26 Sun +1d = Mon (matches), no skip
eq(
  rep.bump("<2026-04-26 Sun +1d[mon,wed,fri]>", "2026-04-26"),
  "<2026-04-27 Mon +1d[mon,wed,fri]>",
  "[mon,wed,fri] hits Mon directly"
)

-- bump with negation: [!sat]
-- 2026-04-25 Fri +1d = Sat → skip → Sun
eq(
  rep.bump("<2026-04-25 Fri +1d[!sat]>", "2026-04-25"),
  "<2026-04-26 Sun +1d[!sat]>",
  "[!sat] skips Sat"
)

-- bump with calendar: [!cal:test]
-- Mock: register a one-off calendar. We do this by injecting a resolver.
rep._test_calendar = function(name, date)
  if name == "test" then
    return date == "2026-04-27" or date == "2026-04-28"
  end
  return false
end
-- 2026-04-26 +1d = 04-27 (in test cal) → skip → 04-28 (in test cal) → skip → 04-29
eq(
  rep.bump("<2026-04-26 Sun +1d[!cal:test]>", "2026-04-26"),
  "<2026-04-29 Wed +1d[!cal:test]>",
  "[!cal:test] skips two days"
)
rep._test_calendar = nil

-- impossible filter: 366-iteration cap
local _, err = rep.bump("<2026-04-26 Sun +1d[wd,we]>", "2026-04-26")
assert(err and err:find("impossible"), "expected impossible-filter error, got " .. tostring(err))

io.write("todo repeater skip ok\n")
os.exit(0)
