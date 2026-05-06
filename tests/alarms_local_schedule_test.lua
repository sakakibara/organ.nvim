-- alarms.lua local_schedule path: collect upcoming agenda rows, flatten
-- across lead_minutes, hand a well-shaped batch to organ.notifier.set_pending.
--
-- The in-process timer path is covered by alarms_test.lua. This test focuses
-- on what the OS-scheduling path emits — that's what survives Neovim closing.
--
-- Run via: nvim --headless -l tests/alarms_local_schedule_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Stub the agenda query so we control the row set.
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

-- Capture set_pending invocations (don't actually shell out).
local set_pending_calls = {}
package.loaded["organ.notifier"] = {
  set_pending = function(entries)
    set_pending_calls[#set_pending_calls + 1] = entries
    return true
  end,
  cancel_all = function()
    return true
  end,
}

local alarms = require("organ.alarms")
local organ = require("organ")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Pin "now" to a deterministic instant so timestamp math is reproducible.
local now = os.time({ year = 2026, month = 5, day = 3, hour = 9, min = 0, sec = 0 })
local function iso(ts)
  return os.date("%Y-%m-%dT%H:%M", ts)
end

-- ---------------------------------------------------------------------------
-- 1. Two future scheduled rows × lead_minutes={10,0} → four entries.
-- ---------------------------------------------------------------------------
organ.config = organ.config or {}
organ.config.alarms = {
  enabled = true,
  local_schedule = true,
  lead_minutes = { 10, 0 },
  lookahead_hours = 48,
}

stub_rows = {
  { id = "h1", title = "Standup", todo_state = "TODO", scheduled = iso(now + 1800) }, -- in 30 min
  { id = "h2", title = "Review", todo_state = "TODO", scheduled = iso(now + 7200) }, -- in 2h
}

set_pending_calls = {}
alarms.scan(now)
check("scan dispatched to notifier", #set_pending_calls == 1)

local entries = set_pending_calls[1]
check("emitted 4 entries (2 rows × 2 lead times)", #entries == 4, "got " .. #entries)

-- All entries must have the four required fields. Notifier backends drop
-- entries where any are missing → silent miss.
for i, e in ipairs(entries) do
  check(("entry[%d]: id present"):format(i), type(e.id) == "string" and #e.id > 0)
  check(("entry[%d]: at present + future"):format(i), type(e.at) == "number" and e.at >= now)
  check(("entry[%d]: title present"):format(i), type(e.title) == "string")
  check(("entry[%d]: body present"):format(i), type(e.body) == "string")
end

-- ID format includes both the row id and the lead minutes — required for
-- dedup to work across overlapping scans (same row, same lead → same id).
local seen_ids = {}
for _, e in ipairs(entries) do
  seen_ids[e.id] = (seen_ids[e.id] or 0) + 1
end
local unique = 0
for _ in pairs(seen_ids) do
  unique = unique + 1
end
check(
  "entry ids are unique across the batch",
  unique == 4,
  "got " .. unique .. " unique ids out of 4"
)

-- Body wording differs between lead > 0 and lead == 0.
local has_in_min, has_now = false, false
for _, e in ipairs(entries) do
  if e.body:find("in 10 min", 1, true) then
    has_in_min = true
  end
  if e.body:find("— now", 1, true) then
    has_now = true
  end
end
check("body wording: 'in 10 min' for lead=10", has_in_min)
check("body wording: '— now' for lead=0", has_now)

-- ---------------------------------------------------------------------------
-- 2. Same row scanned twice produces the same ids → notifier idempotency
--    (set_pending replaces the previous batch; same ids = same effective
--    schedule).
-- ---------------------------------------------------------------------------
local first_ids = {}
for _, e in ipairs(entries) do
  first_ids[e.id] = true
end

set_pending_calls = {}
alarms.scan(now)
local second = set_pending_calls[1]
local matched = 0
for _, e in ipairs(second) do
  if first_ids[e.id] then
    matched = matched + 1
  end
end
check(
  "re-scan produces identical ids (idempotent)",
  matched == #second,
  "matched " .. matched .. "/" .. #second
)

-- ---------------------------------------------------------------------------
-- 3. Past-due row with lead=0 produces no entry; with lead=10 may still
--    emit an entry if (due - 10min) is still in the future. Confirm the
--    boundary: a row 5 min ago, lead {10, 0} → zero entries (both leads
--    fall before now).
-- ---------------------------------------------------------------------------
stub_rows = {
  { id = "past", title = "Old", todo_state = "TODO", scheduled = iso(now - 300) }, -- 5 min ago
}
set_pending_calls = {}
alarms.scan(now)
check(
  "past-due row produces zero entries",
  #set_pending_calls == 1 and #set_pending_calls[1] == 0,
  "got " .. (set_pending_calls[1] and #set_pending_calls[1] or "nil")
)

-- ---------------------------------------------------------------------------
-- 4. Empty agenda → set_pending called with empty list (cancels prior batch).
-- ---------------------------------------------------------------------------
stub_rows = {}
set_pending_calls = {}
alarms.scan(now)
check(
  "empty agenda: still calls set_pending (with [])",
  #set_pending_calls == 1 and #set_pending_calls[1] == 0
)

-- ---------------------------------------------------------------------------
-- 5. local_schedule=false → notifier not invoked at all.
-- ---------------------------------------------------------------------------
organ.config.alarms.local_schedule = false
set_pending_calls = {}
stub_rows = {
  { id = "h3", title = "Standup", todo_state = "TODO", scheduled = iso(now + 600) },
}
alarms.scan(now)
check(
  "local_schedule=false: notifier NOT called",
  #set_pending_calls == 0,
  "got " .. #set_pending_calls .. " calls"
)

-- ---------------------------------------------------------------------------
-- 6. enabled=false → no scan happens at all.
-- ---------------------------------------------------------------------------
organ.config.alarms.enabled = false
organ.config.alarms.local_schedule = true
set_pending_calls = {}
alarms.scan(now)
check("enabled=false: notifier NOT called even with local_schedule=true", #set_pending_calls == 0)

alarms.stop()

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("alarms_local_schedule_test: PASS")
