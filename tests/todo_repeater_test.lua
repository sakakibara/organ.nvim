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

-- leap-year edge: Feb 29 + 1y → Feb 28 (no such day in target year)
eq(rep.bump("<2024-02-29 Thu +1y>", "2024-02-29"), "<2025-02-28 Fri +1y>", "leap-year edge")

-- inactive timestamp brackets preserved
eq(rep.bump("[2026-04-20 Mon +1w]", "2026-04-26"), "[2026-04-27 Mon +1w]", "inactive brackets")

io.write("todo repeater ok\n")
os.exit(0)
