-- Pure unit on todo/repeater.lua: parse + bump for +, ++, .+ kinds.
-- Run via: nvim --headless -l tests/todo_repeater_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local rep = require("organ.todo.repeater")

local function eq(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

-- parse: returns table on hit, nil on miss
local p = rep.parse("<2026-04-13 Mon +1w>")
assert(p and p.kind == "+" and p.value == 1 and p.unit == "w", "parse +1w")
local p2 = rep.parse("<2026-04-13 Mon ++2m>")
assert(p2 and p2.kind == "++" and p2.value == 2 and p2.unit == "m", "parse ++2m")
local p3 = rep.parse("<2026-04-13 Mon .+3d>")
assert(p3 and p3.kind == ".+" and p3.value == 3 and p3.unit == "d", "parse .+3d")
assert(rep.parse("<2026-04-13 Mon>") == nil, "no repeater → nil")

-- A zero interval is not a repeater (Emacs `org-auto-repeat-maybe` skips
-- it): parse yields nil and bump refuses instead of stepping forever.
for _, ts in ipairs({
  "<2026-04-13 Mon +0d>",
  "<2026-04-13 Mon 10:00 ++0h>",
  "<2026-04-13 Mon .+0w>",
}) do
  assert(rep.parse(ts) == nil, "zero repeater parses as nil: " .. ts)
end
do
  jit.off()
  debug.sethook(function()
    error("bump on a zero hourly repeater did not return")
  end, "", 2e7)
  local got, err = rep.bump("<2026-04-13 Mon 10:00 ++0h>", "2026-06-01 12:00")
  debug.sethook()
  jit.on()
  assert(got == nil and err, "bump refuses a zero hourly repeater")
end

-- bump "+": single shift
eq(rep.bump("<2026-04-20 Mon +1w>", "2026-04-26"), "<2026-04-27 Mon +1w>", "+1w in future")
eq(
  rep.bump("<2026-04-13 Mon +1w>", "2026-04-26"),
  "<2026-04-20 Mon +1w>",
  "+1w stays in past after single shift"
)

-- bump "++": loops until > today
eq(
  rep.bump("<2026-04-13 Mon ++1w>", "2026-04-26"),
  "<2026-04-27 Mon ++1w>",
  "++1w loops past today"
)

-- bump ".+": today + interval
eq(rep.bump("<2026-04-20 Mon .+1w>", "2026-04-26"), "<2026-05-03 Sun .+1w>", ".+1w from today")

-- units: d, w, m, y
eq(rep.bump("<2026-04-26 Sun +3d>", "2026-04-26"), "<2026-04-29 Wed +3d>", "+3d")
eq(rep.bump("<2026-04-26 Sun +1m>", "2026-04-26"), "<2026-05-26 Tue +1m>", "+1m")
eq(rep.bump("<2026-04-26 Sun +1y>", "2026-04-26"), "<2027-04-26 Mon +1y>", "+1y")

-- Month/year shifts overflow past short months like Emacs `encode-time`
-- (org-timestamp-change): no clamping to the target month's length.
eq(rep.bump("<2026-01-31 Sat +1m>", "2026-05-04"), "<2026-03-03 Tue +1m>", "Jan 31 +1m overflows")
eq(rep.bump("<2024-01-31 Wed +1m>", "2024-05-04"), "<2024-03-02 Sat +1m>", "Jan 31 +1m leap year")
eq(rep.bump("<2026-03-31 Tue +1m>", "2026-05-04"), "<2026-05-01 Fri +1m>", "Mar 31 +1m")
eq(rep.bump("<2024-02-29 Thu +1y>", "2024-02-29"), "<2025-03-01 Sat +1y>", "Feb 29 +1y")
eq(
  rep.bump("<2026-01-31 Sat ++1m>", "2026-05-04"),
  "<2026-06-03 Wed ++1m>",
  "++1m carries each overflow forward"
)

-- inactive timestamp brackets preserved
eq(rep.bump("[2026-04-20 Mon +1w]", "2026-04-26"), "[2026-04-27 Mon +1w]", "inactive brackets")

-- hourly repeaters shift the clock time and roll the date when needed.
local ph = rep.parse("<2026-05-04 Mon 10:00 +2h>")
assert(ph and ph.kind == "+" and ph.value == 2 and ph.unit == "h", "parse +2h")
eq(rep.bump("<2026-05-04 Mon 10:00 +2h>", "2026-05-04 11:00"), "<2026-05-04 Mon 12:00 +2h>", "+2h")
eq(
  rep.bump("<2026-05-04 Mon 23:00 +2h>", "2026-05-04"),
  "<2026-05-05 Tue 01:00 +2h>",
  "+2h rolls into the next day"
)
eq(
  rep.bump("<2026-05-04 Mon 10:00-11:00 +2h>", "2026-05-04"),
  "<2026-05-04 Mon 12:00-13:00 +2h>",
  "+2h shifts both ends of a range"
)
eq(
  rep.bump("<2026-05-04 Mon 23:00-23:30 +2h>", "2026-05-04"),
  "<2026-05-05 Tue 01:00-01:30 +2h>",
  "+2h range across midnight"
)
eq(
  rep.bump("[2026-05-04 Mon 23:00 +2h]", "2026-05-04"),
  "[2026-05-05 Tue 01:00 +2h]",
  "+2h inactive"
)
eq(
  rep.bump("<2026-05-04 Mon 10:00 ++2h>", "2026-05-04 15:30"),
  "<2026-05-04 Mon 16:00 ++2h>",
  "++2h loops past now"
)
eq(
  rep.bump("<2026-05-04 Mon 10:00 .+2h>", "2026-05-04 15:30"),
  "<2026-05-04 Mon 17:30 .+2h>",
  ".+2h from now"
)
do
  local got, err = rep.bump("<2026-05-04 Mon +2h>", "2026-05-04")
  assert(got == nil and err and err:find("no hour"), "hourly repeater without a time errors")
end

io.write("todo repeater ok\n")
os.exit(0)
