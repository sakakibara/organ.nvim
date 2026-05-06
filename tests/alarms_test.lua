-- Verifies organ.alarms schedules a libuv timer per (row, lead) and fires.
-- Run via: nvim --headless -l tests/alarms_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local alarms = require("organ.alarms")
local organ = require("organ")

-- Stub the agenda query so we don't need a DB.
package.loaded["organ.query"] = nil
local stub_rows
package.loaded["organ.query"] = setmetatable({}, {
  __index = function(_, k)
    if k == "agenda" then
      return function()
        return stub_rows or {}
      end
    end
    return nil
  end,
})

-- 1. Disabled by default → no timers.
organ.config = organ.config or {}
organ.config.alarms = { enabled = false }
alarms.scan(os.time())
assert(#alarms._state().timers == 0, "no timers when disabled")

-- 2. With a row scheduled in the next minute and lead_minutes={0}, fire.
-- We monkey-patch the parse function so the test stays under 3 seconds.
local fired_payloads = {}
organ.config.alarms = {
  enabled = true,
  lead_minutes = { 0 },
  notify = function(row, lead, ts)
    fired_payloads[#fired_payloads + 1] = { row = row, lead = lead, ts = ts }
  end,
  scan_interval_seconds = 9999,
}

local now = os.time()
-- Round up to the next full minute, then add 1 minute for safety: ensures
-- parse_iso_to_ts(iso) > now even after second-truncation in os.date.
local target_ts = math.floor(now / 60) * 60 + 60
-- We can't actually wait a full minute in tests; instead we directly invoke
-- the dispatcher by faking `now` as 1s before the target.
local iso = os.date("%Y-%m-%dT%H:%M", target_ts)
stub_rows = {
  { id = "row1", title = "Standup", todo_state = "TODO", scheduled = iso },
}

alarms.scan(target_ts - 1)
assert(#alarms._state().timers == 1, "one timer expected, got " .. #alarms._state().timers)

-- The timer is set ~1000ms out. Wait up to 3s for it to fire.
local ok = vim.wait(3000, function()
  return #fired_payloads > 0
end, 50)
assert(
  ok and fired_payloads[1].row.id == "row1",
  "alarm did not fire within 3s (waited=" .. tostring(ok) .. ", payloads=" .. #fired_payloads .. ")"
)

-- 3. Already-DONE rows are skipped.
fired_payloads = {}
stub_rows = {
  { id = "row2", title = "Done thing", todo_state = "DONE", scheduled = iso },
}
alarms.scan(os.time())
-- DONE rows should produce no timers.
assert(#alarms._state().timers == 0, "DONE row must not schedule")

-- 4. Past-due rows produce no timer (alarm is in the past).
fired_payloads = {}
stub_rows = {
  {
    id = "row3",
    title = "Old",
    todo_state = "TODO",
    scheduled = os.date("%Y-%m-%dT%H:%M", os.time() - 3600),
  },
}
alarms.scan(os.time())
assert(#alarms._state().timers == 0, "past-due rows skipped")

-- Clean up.
alarms.stop()
io.write("alarms ok\n")
os.exit(0)
