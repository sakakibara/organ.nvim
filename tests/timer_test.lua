-- Countdown timer (Emacs `org-timer-set-timer`).
-- Tests: duration parsing, start/stop/pause/resume state machine,
-- expiry-fires-on-zero behavior, statusline component.
-- Run via: nvim --headless -l tests/timer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local timer = require("organ.timer")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- 1. Duration parsing.
check("plain '25' → 1500s (minutes default)", timer._parse_duration("25") == 25 * 60)
check("'25m' → 1500s", timer._parse_duration("25m") == 25 * 60)
check("'90s' → 90s", timer._parse_duration("90s") == 90)
check("'1h' → 3600s", timer._parse_duration("1h") == 3600)
check("'1h30m' → 5400s", timer._parse_duration("1h30m") == 5400)
check("'0:25:00' → 1500s", timer._parse_duration("0:25:00") == 25 * 60)
check("'25:00' (m:s) → 1500s", timer._parse_duration("25:00") == 25 * 60)
check("garbage → nil", timer._parse_duration("not-a-duration") == nil)
check("empty → nil", timer._parse_duration("") == nil)

-- 2. Start.
timer.start("5m")
local s = timer.status()
check("after start: status is 'running'", s.status == "running")
check("after start: duration_s == 300", s.duration_s == 300)
check(
  "after start: remaining is roughly 300",
  s.remaining and s.remaining >= 299 and s.remaining <= 300
)
check("statusline shows ⏲ HH:MM", timer.statusline():find("⏲") ~= nil)

-- 3. Pause + resume.
timer.pause()
check("after pause: status is 'paused'", timer.status().status == "paused")
check("paused statusline shows ⏸", timer.statusline():find("⏸") ~= nil)
timer.pause() -- resume
check("after second pause: status is 'running'", timer.status().status == "running")

-- 4. Stop clears state.
timer.stop()
check("after stop: status is nil", timer.status().status == nil)
check("statusline empty when no timer", timer.statusline() == "")
check("remaining nil when no timer", timer.remaining() == nil)

-- 5. Default duration.
timer.start()
check("start() with no arg uses default 25m", timer.status().duration_s == 25 * 60)
timer.stop()

-- 6. Expiry: short-duration start lets the uv timer fire.
local fired = false
require("organ.events").on("organ.timer.expired", function()
  fired = true
end)
timer.start("1s")
vim.wait(2000, function()
  return fired
end, 50)
check("expiry event fires after duration elapses", fired == true)
check("after expiry: status cleared", timer.status().status == nil)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("timer_test: PASS")
