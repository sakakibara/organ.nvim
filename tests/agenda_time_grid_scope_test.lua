-- Time grid scope: `on = "today"` (default) only emits the grid for
-- today's day-bucket. `on = "all"` emits for every day in the window.
--
-- Run via: nvim --headless -l tests/agenda_time_grid_scope_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Two-day sample. The render uses now="2026-05-03" so:
--   today  = "2026-05-03" (Sunday)
--   non-today = "2026-05-04" (Monday)
local SAMPLE = {
  {
    id = "h1",
    file_path = "/work.org",
    title = "Today task",
    line_start = 4,
    level = 1,
    todo_state = "TODO",
    scheduled_date = "2026-05-03T09:00",
    tags = {},
  },
  {
    id = "h2",
    file_path = "/work.org",
    title = "Tomorrow task",
    line_start = 8,
    level = 1,
    todo_state = "TODO",
    scheduled_date = "2026-05-04T15:00",
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
  todo = { sequence = { "TODO", "|", "DONE" } },
})

local agenda = require("organ.agenda")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function render(scope)
  require("organ").config.agenda.time_grid = {
    hours = { 8, 10, 12, 14, 16 },
    on = scope,
  }
  -- Suppress now-marker so we only assert about grid lines.
  require("organ").config.agenda.now_marker = false
  local out = agenda.render({
    {
      block = {
        kind = "agenda",
        from = "2026-05-03",
        to = "2026-05-04",
        group_by = "day",
      },
      rows = SAMPLE,
    },
  }, { now = "2026-05-03" })
  return out.lines
end

-- scope = "today"
do
  local lines = render("today")
  -- Find the index of each date header so we can scope the grid search.
  local sun_idx, mon_idx
  for i, l in ipairs(lines) do
    if l:find("Sunday", 1, true) then
      sun_idx = i
    end
    if l:find("Monday", 1, true) then
      mon_idx = i
    end
  end
  check("scope='today': both day headers present", sun_idx ~= nil and mon_idx ~= nil)

  -- An *empty* grid line looks like `  HH:MM ┄┄┄┄┄ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄`
  -- (two ┄-groups separated by a space).  A timed row also contains
  -- ` ┄┄┄┄┄ ` after the time, so just searching `┄┄` is too loose;
  -- match the second ┄-group's two-dash prefix to disambiguate.
  local GRID_PAT = "┄┄┄┄┄ ┄┄"
  local function has_grid_between(a, b)
    for i = a + 1, (b or #lines) do
      if lines[i] and lines[i]:find(GRID_PAT, 1, true) then
        return true
      end
    end
    return false
  end
  check("scope='today': grid lines INSIDE Sunday bucket", has_grid_between(sun_idx, mon_idx))
  check("scope='today': NO grid lines INSIDE Monday bucket", not has_grid_between(mon_idx))
end

-- scope = "all"
do
  local lines = render("all")
  local sun_idx, mon_idx
  for i, l in ipairs(lines) do
    if l:find("Sunday", 1, true) then
      sun_idx = i
    end
    if l:find("Monday", 1, true) then
      mon_idx = i
    end
  end
  local GRID_PAT = "┄┄┄┄┄ ┄┄"
  local function has_grid_between(a, b)
    for i = a + 1, (b or #lines) do
      if lines[i] and lines[i]:find(GRID_PAT, 1, true) then
        return true
      end
    end
    return false
  end
  check("scope='all': grid lines INSIDE Sunday bucket", has_grid_between(sun_idx, mon_idx))
  check("scope='all': grid lines INSIDE Monday bucket too", has_grid_between(mon_idx))
end

-- time_grid disabled
do
  require("organ").config.agenda.time_grid = false
  local out = agenda.render({
    {
      block = {
        kind = "agenda",
        from = "2026-05-03",
        to = "2026-05-04",
        group_by = "day",
      },
      rows = SAMPLE,
    },
  }, { now = "2026-05-03" })
  local has_any_grid = false
  for _, l in ipairs(out.lines) do
    if l:find("┄┄┄┄┄ ┄┄", 1, true) then
      has_any_grid = true
      break
    end
  end
  check("time_grid=false: no grid lines anywhere", not has_any_grid)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_time_grid_scope_test: PASS")
