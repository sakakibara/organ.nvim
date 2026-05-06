-- Time grid (Emacs `org-agenda-use-time-grid`).
--
-- When agenda.time_grid is enabled, today's day-bucket gets one line
-- per configured grid hour. Rows scheduled at a grid hour replace that
-- hour's blank line; non-grid times insert their own line in time order.
--
-- Run via: nvim --headless -l tests/agenda_time_grid_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local SAMPLE = {
  {
    id = "h1",
    file_path = "/work.org",
    title = "Standup",
    line_start = 4,
    level = 1,
    todo_state = "TODO",
    scheduled_date = "2026-05-03T09:00",
    tags = {},
  },
  {
    id = "h2",
    file_path = "/work.org",
    title = "Design review",
    line_start = 12,
    level = 1,
    todo_state = "NEXT",
    scheduled_date = "2026-05-03T15:30",
    tags = {},
  },
  {
    id = "h3",
    file_path = "/work.org",
    title = "All-day task",
    line_start = 20,
    level = 1,
    todo_state = "TODO",
    scheduled_date = "2026-05-03", -- date only, no time
    tags = {},
  },
}

package.loaded["organ.query"] = {
  agenda = function()
    return SAMPLE
  end,
  headlines = function()
    return SAMPLE
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
  agenda = {
    time_grid = { hours = { 8, 10, 12, 14, 16, 18 }, on = "all" },
    now_marker = false, -- isolate grid behavior from now-marker
  },
})

local agenda = require("organ.agenda")

local out = agenda.render({
  {
    block = {
      kind = "agenda",
      from = "2026-05-03",
      to = "2026-05-03",
      group_by = "day",
    },
    rows = SAMPLE,
  },
}, { now = "2026-05-03" })
local lines = out.lines

print()
print("==== render ====")
for _, l in ipairs(lines) do
  print(l)
end
print("================")
print()

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function find_line(needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return l
    end
  end
  return nil
end

-- Grid lines for hours that have NO row scheduled.
check("grid line for 08:00 (empty hour) present", find_line("8:00 ┄┄") ~= nil)
check("grid line for 10:00 (empty hour) present", find_line("10:00 ┄┄") ~= nil)
check("grid line for 12:00 (empty hour) present", find_line("12:00 ┄┄") ~= nil)

-- 09:00 grid SHOULD be replaced by the Standup row (row at exactly 09:00).
check("Standup row present (09:00)", find_line("Standup") ~= nil)
check(
  "09:00 has NO empty grid line (Standup occupies it)",
  (function()
    for _, l in ipairs(lines) do
      if
        l:find("9:00 ┄┄┄┄┄ ┄┄", 1, true)
        or l:find("09:00 ┄┄┄┄┄ ┄┄", 1, true)
      then
        return false
      end
    end
    return true
  end)()
)

-- 15:30 row appears at its own time (non-grid hour).
check("Design review row present (15:30 — non-grid time)", find_line("Design review") ~= nil)

-- All-day row is rendered AFTER the grid (untimed bucket).
local function index_of(needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i
    end
  end
end
local i_all_day = index_of("All-day task")
local i_grid_18 = index_of("18:00 ┄┄")
check(
  "untimed all-day row appears after the last grid hour",
  i_all_day and i_grid_18 and i_all_day > i_grid_18,
  "all_day at " .. tostring(i_all_day) .. ", 18:00 at " .. tostring(i_grid_18)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_time_grid_test: PASS")
