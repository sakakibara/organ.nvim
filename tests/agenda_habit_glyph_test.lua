-- Verifies habit headlines in :Org agenda render an inline glyph row.
-- Run via: nvim --headless -l tests/agenda_habit_glyph_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Habit graphs are off by default (Emacs parity); flip on for this test.
require("organ").config.agenda = require("organ").config.agenda or {}
require("organ").config.agenda.show_habit_graphs = true

local agenda = require("organ.agenda")
local habit = require("organ.habit")

local today = "2026-04-29"
local yesterday = "2026-04-28"

local rows = {
  {
    id = "h1",
    title = "Daily standup",
    todo_state = "TODO",
    priority = nil,
    scheduled = "<" .. today .. " Wed .+1d/2d>",
    scheduled_date = today,
    tags = {},
    file_path = "/h.org",
    line_start = 5,
    level = 1,
    properties = { STYLE = "habit" },
    is_habit = true,
    habit_period_days = 1,
    habit_alarm_days = 2,
    completions = { yesterday },
    _today = today,
    habit_glyph_days = 7,
  },
}

local out = agenda.render({
  { block = { group_by = "none" }, rows = rows },
}, { now = today })

local joined = table.concat(out.lines, "\n")
assert(joined:find("Daily standup", 1, true), "habit title missing:\n" .. joined)

-- Glyph row lives after the location and before/after tags. Look for the
-- expected glyph characters in the rendered line.
local glyphs = habit.render_glyph_row(
  { completions = { yesterday }, scheduled_date = today, period_days = 1, alarm_days = 2 },
  today,
  7
)
assert(
  joined:find(glyphs, 1, true),
  "glyph row '" .. glyphs .. "' not present in rendered line:\n" .. joined
)

-- An extmark must apply a habit hl group somewhere on the row.
local found_habit_hl = false
for _, mk in ipairs(out.extmarks) do
  local hl = mk[2]
  if
    hl == "OrgHabitDone"
    or hl == "OrgHabitClear"
    or hl == "OrgHabitOverdue"
    or hl == "OrgHabitAhead"
    or hl == "OrgHabitLate"
  then
    found_habit_hl = true
    break
  end
end
assert(found_habit_hl, "no habit highlight extmark emitted")

io.write("agenda habit glyph ok\n")
os.exit(0)
