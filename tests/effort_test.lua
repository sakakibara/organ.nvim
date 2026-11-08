-- Verifies organ.effort parsing + agenda clock-budget integration.
-- Run via: nvim --headless -l tests/effort_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local effort = require("organ.effort")

-- Parse forms: org-duration's reading.
assert(effort.parse("30") == 30, "bare integer = 30 min")
assert(effort.parse("1:30") == 90, "HH:MM")
assert(effort.parse("1:30:15") == 90.25, "H:MM:SS")
assert(effort.parse("2h") == 120, "Xh")
assert(effort.parse("30min") == 30, "Xmin")
assert(effort.parse("30m") == 30 * 43200, "Xm is months")
assert(effort.parse("1.5h") == 90, "decimal hours")
assert(effort.parse("0.5") == 0.5, "bare decimal = minutes")
assert(effort.parse("1d") == 24 * 60, "Xd")
assert(effort.parse("1w") == 7 * 24 * 60, "Xw")
assert(effort.parse("1d 2:30") == 24 * 60 + 150, "mixed units and H:MM")
assert(effort.parse("2hr") == nil, "2hr is not a duration")
assert(effort.parse("1h30") == nil, "1h30 is not a duration")
assert(effort.parse("nonsense") == nil, "unparseable returns nil")
assert(effort.parse("") == nil, "empty string returns nil")
assert(effort.parse("  ") == nil, "blank returns nil")
assert(effort.parse(" \t") == nil, "blank with a tab returns nil")
assert(effort.parse(nil) == nil, "nil returns nil")

-- row_effort_minutes
assert(effort.row_effort_minutes({ properties = { EFFORT = "1:00" } }) == 60)
assert(effort.row_effort_minutes({ properties = { effort = "30" } }) == 30)
assert(effort.row_effort_minutes({}) == nil)

-- clocked_minutes from a list of entries.
assert(effort.clocked_minutes({}) == 0)
assert(effort.clocked_minutes({ { duration_seconds = 1800 } }) == 30)
assert(effort.clocked_minutes({
  { duration_seconds = 1800 },
  { duration_seconds = 600 },
}) == 40)

-- Agenda integration: format_line should render an effort segment when
-- :EFFORT: is set.
local agenda = require("organ.agenda")
local rows = {
  {
    id = "e1",
    title = "Coding task",
    todo_state = "TODO",
    scheduled_date = "2026-04-29",
    properties = { EFFORT = "2:00" },
    clocked_minutes = 60,
    tags = {},
    file_path = "/x.org",
    line_start = 1,
    level = 1,
  },
}

local out = agenda.render({
  { block = { group_by = "none" }, rows = rows },
}, { now = "2026-04-29" })

local joined = table.concat(out.lines, "\n")
assert(
  joined:find("[1:00/2:00]", 1, true),
  "expected '[1:00/2:00]' clock-budget in agenda line:\n" .. joined
)

-- With no clock yet, only estimated shows.
rows[1].clocked_minutes = nil
out = agenda.render({
  { block = { group_by = "none" }, rows = rows },
}, { now = "2026-04-29" })
joined = table.concat(out.lines, "\n")
assert(
  joined:find("[2:00]", 1, true) and not joined:find("/", 1, true) or joined:find("[2:00]", 1, true),
  "expected '[2:00]' (no clock):\n" .. joined
)

-- Disabled in config → no segment.
local organ = require("organ")
organ.config.effort = { show_in_agenda = false }
out = agenda.render({
  { block = { group_by = "none" }, rows = rows },
}, { now = "2026-04-29" })
joined = table.concat(out.lines, "\n")
assert(
  not joined:find("[2:00]", 1, true),
  "effort segment should be hidden when show_in_agenda = false"
)

organ.config.effort = nil

local function render_effort(props, clocked)
  rows[1].properties = props
  rows[1].clocked_minutes = clocked
  return table.concat(
    agenda.render({ { block = { group_by = "none" }, rows = rows } }, { now = "2026-04-29" }).lines,
    "\n"
  )
end

-- A fractional estimate prints as H:MM.
joined = render_effort({ EFFORT = "1:30:15" }, nil)
assert(joined:find("[1:30]", 1, true), "expected '[1:30]' for 1:30:15:\n" .. joined)

-- Clocked part with a fractional estimate.
joined = render_effort({ EFFORT = "1:30:15" }, 45)
assert(joined:find("[0:45/1:30]", 1, true), "expected '[0:45/1:30]':\n" .. joined)

-- An invalid value and a blank one give no segment.
for _, v in ipairs({ "abc", "1h30", "", "  " }) do
  joined = render_effort({ EFFORT = v }, nil)
  assert(
    not joined:find("[", 1, true),
    "expected no effort segment for " .. vim.inspect(v) .. ":\n" .. joined
  )
end

-- A value that reads but is past the printable range gives no segment.
joined = render_effort({ EFFORT = "200000000000000" }, nil)
assert(not joined:find("[", 1, true), "expected no effort segment out of range:\n" .. joined)

io.write("effort ok\n")
os.exit(0)
