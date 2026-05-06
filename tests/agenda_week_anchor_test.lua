-- M.week() anchors the weekly agenda to the configured start-of-week
-- day (default Monday, matching Emacs `org-agenda-start-on-weekday`).
-- Without this, opening :Org agenda week mid-week showed today..+6d
-- instead of Mon..Sun.
--
-- Run via: nvim --headless -l tests/agenda_week_anchor_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

-- Capture the view that M.week() hands to M.open by stubbing M.open.
local agenda = require("organ.agenda")
local captured
local orig_open = agenda.open
agenda.open = function(view)
  captured = view
end

agenda.week()
agenda.open = orig_open

check("M.week() handed a view to open", captured ~= nil)
check("from is set", captured and captured.from ~= nil)
check("to is set", captured and captured.to ~= nil)

-- Verify "from" is a Monday (ISO weekday 1).
local function iso_weekday(date_str)
  local y, m, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  local ts = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local w = tonumber(os.date("%w", ts)) -- 0=Sun..6=Sat
  return (w == 0) and 7 or w
end

check(
  "from is a Monday (ISO weekday 1)",
  iso_weekday(captured.from) == 1,
  string.format("from=%s weekday=%d", captured.from, iso_weekday(captured.from))
)

check(
  "to is six days after from (Sunday)",
  (function()
    local fy, fm, fd = captured.from:match("^(%d+)%-(%d+)%-(%d+)$")
    local ty, tm, td = captured.to:match("^(%d+)%-(%d+)%-(%d+)$")
    local from_ts =
      os.time({ year = tonumber(fy), month = tonumber(fm), day = tonumber(fd), hour = 12 })
    local to_ts =
      os.time({ year = tonumber(ty), month = tonumber(tm), day = tonumber(td), hour = 12 })
    return math.floor((to_ts - from_ts) / 86400) == 6
  end)(),
  string.format("from=%s to=%s", captured.from, captured.to)
)

check("to is a Sunday (ISO weekday 7)", iso_weekday(captured.to) == 7)

-- week_starts_on = "sunday" -> Sunday-anchored week.
require("organ").config.agenda.week_starts_on = "sunday"
captured = nil
agenda.open = function(view)
  captured = view
end
agenda.week()
agenda.open = orig_open
check("week_starts_on='sunday' -> from is a Sunday", iso_weekday(captured.from) == 7)
check("week_starts_on='sunday' -> to is the following Saturday", iso_weekday(captured.to) == 6)

-- week_starts_on = "today" disables the fixed anchor: window is
-- today..+6d regardless of weekday.
require("organ").config.agenda.week_starts_on = "today"
captured = nil
agenda.open = function(view)
  captured = view
end
agenda.week()
agenda.open = orig_open
check(
  "week_starts_on='today' -> from is today",
  captured.from == os.date("%Y-%m-%d"),
  "from=" .. tostring(captured.from)
)
check(
  "week_starts_on='today' -> to is today+6",
  captured.to == os.date("%Y-%m-%d", os.time() + 6 * 86400),
  "to=" .. tostring(captured.to)
)
require("organ").config.agenda.week_starts_on = nil

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_week_anchor_test: PASS")
