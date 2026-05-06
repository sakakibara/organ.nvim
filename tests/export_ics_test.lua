-- ICS export: VEVENT per SCHEDULED/DEADLINE; all-day vs timed; UID;
-- line folding at 75-octet boundary.
-- Run via: nvim --headless -l tests/export_ics_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local ics = require("organ.export.ics")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

-- 1. parse_org_ts: all-day, timed, time-range.
do
  local p = ics._parse_org_ts("<2026-05-02 Sat>")
  assert(p.all_day and p.date == "20260502", "all-day parse")
  p = ics._parse_org_ts("<2026-05-02 Sat 14:30>")
  assert(p.start_time == "143000" and not p.end_time, "timed start only")
  p = ics._parse_org_ts("<2026-05-02 Sat 14:30-15:00>")
  assert(p.end_time == "150000", "time-range end")
end

-- 2. End-to-end: buffer with one SCHEDULED, one DEADLINE.
local out = ics.export([[
* TODO Standup :work:
  :PROPERTIES:
  :ID: standup-uuid
  :END:
  SCHEDULED: <2026-05-04 Mon 09:00-09:15>
* TODO Project :work:
  DEADLINE: <2026-05-15 Fri>
]])

assert_contains(out, "BEGIN:VCALENDAR")
assert_contains(out, "END:VCALENDAR")
assert_contains(out, "VERSION:2.0")
-- Two events.
local n_begin = 0
for _ in out:gmatch("BEGIN:VEVENT") do
  n_begin = n_begin + 1
end
assert(n_begin == 2, "expected 2 VEVENTs; got " .. n_begin)
-- Standup: timed, has UID from :ID:, time range → DTSTART + DTEND.
assert_contains(out, "UID:standup-uuid")
assert_contains(out, "DTSTART:20260504T090000")
assert_contains(out, "DTEND:20260504T091500")
assert_contains(out, "SUMMARY:Standup")
-- Deadline: all-day → VALUE=DATE form; SUMMARY prefixed with "(Deadline)".
assert_contains(out, "DTSTART;VALUE=DATE:20260515")
assert_contains(out, "SUMMARY:(Deadline) Project")

-- 3. Line folding: lines ≤ 75 octets stay intact; longer ones get folded.
do
  local short = ics._fold_line("SHORT")
  assert(short == "SHORT", "short stays intact")
  local long = ics._fold_line(string.rep("X", 200))
  assert(long:find("\r\n ", 1, true), "long line should fold with CRLF + space")
end

io.write("export ics ok\n")
os.exit(0)
