-- Habit module unit tests.
-- Run via: nvim --headless -l tests/habit_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local hab = require("organ.habit")

local function eq(a, b, label)
  if a ~= b then
    error(label .. ": expected " .. tostring(b) .. ", got " .. tostring(a))
  end
end

local function deq(a, b, label)
  if vim.deep_equal(a, b) ~= true then
    error(label .. ": expected " .. vim.inspect(b) .. ", got " .. vim.inspect(a))
  end
end

-- is_habit: case-insensitive STYLE = habit
assert(hab.is_habit({ STYLE = "habit" }), "STYLE: habit")
assert(hab.is_habit({ STYLE = "HABIT" }), "uppercase value")
assert(hab.is_habit({ Style = "habit" }), "Style key variant")
assert(not hab.is_habit({ STYLE = "boxed" }), "non-habit STYLE")
assert(not hab.is_habit({}), "no properties")
assert(not hab.is_habit(nil), "nil properties")

-- parse_completions: extract sorted DONE dates
do
  local logbook = [[
- State "DONE"      from "TODO"      [2026-04-20 Mon 09:00]
- State "DONE"      from "TODO"      [2026-04-22 Wed 09:00]
- State "DONE"      from "TODO"      [2026-04-21 Tue 09:00]
- State "TODO"      from "DONE"      [2026-04-23 Thu 09:00]
- State "DONE"      from "TODO"      [2026-04-24 Fri 09:00]
]]
  deq(
    hab.parse_completions(logbook),
    { "2026-04-20", "2026-04-21", "2026-04-22", "2026-04-24" },
    "completions sorted, dedup, ignores reverse transitions"
  )
  -- Emacs leaves `from` empty (no quotes) when there was no previous state.
  local emacs_shaped = [[
- State "DONE"       from              [2026-04-25 Sat 09:00]
- State "DONE"       from "TODO"       [2026-04-26 Sun 09:00]
]]
  deq(
    hab.parse_completions(emacs_shaped),
    { "2026-04-25", "2026-04-26" },
    "parses Emacs no-previous-state entries"
  )
end

-- period_days
eq(hab.period_days({ value = 1, unit = "d" }), 1, "1d → 1")
eq(hab.period_days({ value = 2, unit = "w" }), 14, "2w → 14")
eq(hab.period_days({ value = 1, unit = "m" }), 30, "1m → 30")

-- alarm_days
eq(hab.alarm_days({ deadline_value = 3, deadline_unit = "d" }), 3, "/3d")
eq(hab.alarm_days({}), nil, "no deadline")

-- streak: consecutive daily completions
do
  -- April 18, 19, 20, 21 — 4-day streak.
  local s = hab.streak({ "2026-04-18", "2026-04-19", "2026-04-20", "2026-04-21" }, 1)
  eq(s, 4, "4-day daily streak")
end

do
  -- Streak broken by gap: 18, 19, (skip 20), 21.  Latest streak = 1 (just 21).
  local s = hab.streak({ "2026-04-18", "2026-04-19", "2026-04-21" }, 1)
  eq(s, 1, "broken streak resets to latest")
end

do
  -- Weekly habit (period=7).  Completions every Mon: 4-13, 4-20, 4-27 = 3.
  local s = hab.streak({ "2026-04-13", "2026-04-20", "2026-04-27" }, 7)
  eq(s, 3, "3-week streak")
end

-- longest_streak
do
  local s = hab.longest_streak({
    "2026-04-10",
    "2026-04-11",
    "2026-04-12", -- 3-day run
    "2026-04-15", -- gap
    "2026-04-20",
    "2026-04-21",
    "2026-04-22",
    "2026-04-23", -- 4-day run
  }, 1)
  eq(s, 4, "longest streak picks the 4-run")
end

-- status: done today
eq(hab.status({ completions = { "2026-04-25" } }, "2026-04-25"), "done-today", "done-today")

-- status: scheduled in future = ahead
eq(hab.status({ scheduled_date = "2026-04-26", completions = {} }, "2026-04-25"), "ahead", "ahead")

-- status: due today
eq(
  hab.status({ scheduled_date = "2026-04-25", completions = {} }, "2026-04-25"),
  "due-today",
  "due-today"
)

-- status: approaching (past due, within alarm window)
eq(
  hab.status({
    scheduled_date = "2026-04-23",
    alarm_days = 3,
    completions = {},
  }, "2026-04-25"),
  "approaching",
  "approaching (2 days past, 3-day alarm)"
)

-- status: overdue (past due, beyond alarm)
eq(
  hab.status({
    scheduled_date = "2026-04-20",
    alarm_days = 3,
    completions = {},
  }, "2026-04-25"),
  "overdue",
  "overdue (5 days past, 3-day alarm)"
)

-- status: overdue without alarm
eq(
  hab.status({
    scheduled_date = "2026-04-22",
    completions = {},
  }, "2026-04-25"),
  "overdue",
  "overdue (no alarm window)"
)

-- glyph_row length
do
  local row = hab.glyph_row({ completions = {} }, "2026-04-25", 7)
  eq(#row, 7, "row length matches days arg")
  eq(row[#row].date, "2026-04-25", "rightmost is today")
  eq(row[1].date, "2026-04-19", "leftmost is N-1 days ago")
end

-- glyph_row: completion → done_on_time char
do
  local row = hab.glyph_row({
    completions = { "2026-04-23", "2026-04-24", "2026-04-25" },
    scheduled_date = "2026-04-25",
    period_days = 1,
  }, "2026-04-25", 5)
  eq(row[#row].char, hab.glyphs.done_on_time.char, "today's completion is done_on_time")
end

-- render_glyph_row: returns plain string of char's
do
  local s = hab.render_glyph_row({ completions = {} }, "2026-04-25", 5)
  eq(#s, 5, "render produces N chars")
end

io.write("habit ok\n")
os.exit(0)
