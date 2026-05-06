-- Habit two-period repeater syntax: `.+P/Q`.
-- Run via: nvim --headless -l tests/todo_repeater_habit_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local rep = require("organ.todo.repeater")

local function eq(a, b, label)
  if a ~= b then
    error(label .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  end
end

-- Parse: `.+1d/3d` returns repeat + deadline alarm.
local p = rep.parse("<2026-04-25 Sat .+1d/3d>")
assert(p, "parse returned nil")
eq(p.kind, ".+", "kind")
eq(p.value, 1, "value")
eq(p.unit, "d", "unit")
eq(p.deadline_value, 3, "deadline_value")
eq(p.deadline_unit, "d", "deadline_unit")

-- Parse: `.+1d` (no deadline) returns nil deadline_value.
local p2 = rep.parse("<2026-04-25 Sat .+1d>")
assert(p2, "parse returned nil")
eq(p2.deadline_value, nil, "no deadline_value")
eq(p2.deadline_unit, nil, "no deadline_unit")

-- Bump preserves the `/Nu` suffix in the output timestamp text.
-- Today: 2026-04-25 Sat.  `.+1d` from 2026-04-20 → 2026-04-26.  The
-- `/3d` half is verbatim in the suffix.
eq(
  rep.bump("<2026-04-20 Mon .+1d/3d>", "2026-04-25"),
  "<2026-04-26 Sun .+1d/3d>",
  "bump preserves /3d alarm"
)

-- Multi-week alarm: `.+1w/2w`.
eq(
  rep.bump("<2026-04-20 Mon .+1w/2w>", "2026-04-25"),
  "<2026-05-02 Sat .+1w/2w>",
  "bump preserves /2w alarm"
)

-- Mixed units: `.+2d/1w` (every 2 days, alarm if 1 week passes).
eq(
  rep.bump("<2026-04-20 Mon .+2d/1w>", "2026-04-25"),
  "<2026-04-27 Mon .+2d/1w>",
  "bump preserves mixed-unit alarm"
)

io.write("todo repeater habit ok\n")
os.exit(0)
