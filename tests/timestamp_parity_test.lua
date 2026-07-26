-- Timestamp parser parity with Emacs `org-ts-regexp-both`.
-- Run via: nvim --headless -l tests/timestamp_parity_test.lua

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

local indexer = require("organ.indexer")
local date_iso = indexer._date_iso
local parse = indexer._parse_ts_body

-- Day-of-week label is OPTIONAL (Emacs `org-ts-regexp-both` allows it
-- to be missing).
check(
  "no day-of-week, with time",
  date_iso("<2026-05-06 10:30>") == "2026-05-06T10:30",
  tostring(date_iso("<2026-05-06 10:30>"))
)
check(
  "no day-of-week, date only",
  date_iso("<2026-05-06>") == "2026-05-06",
  tostring(date_iso("<2026-05-06>"))
)

-- Day-of-week label present (the common case).
check(
  "with day-of-week + time",
  date_iso("<2026-05-06 Wed 10:30>") == "2026-05-06T10:30",
  tostring(date_iso("<2026-05-06 Wed 10:30>"))
)
check(
  "with day-of-week, date only",
  date_iso("<2026-05-06 Wed>") == "2026-05-06",
  tostring(date_iso("<2026-05-06 Wed>"))
)

-- Single-digit hours (Emacs accepts).
check(
  "single-digit hour, no day-of-week",
  date_iso("<2026-05-06 9:00>") == "2026-05-06T09:00",
  tostring(date_iso("<2026-05-06 9:00>"))
)
check(
  "single-digit hour, with day-of-week",
  date_iso("<2026-05-06 Wed 9:30>") == "2026-05-06T09:30",
  tostring(date_iso("<2026-05-06 Wed 9:30>"))
)

-- Repeater suffix (`+1d`, `++1w`, `.+1m`).  Date + time still
-- extracted; the repeater is ignored.
check(
  "repeater +1d",
  date_iso("<2026-05-06 Wed 10:00 +1d>") == "2026-05-06T10:00",
  tostring(date_iso("<2026-05-06 Wed 10:00 +1d>"))
)
check(
  "repeater ++1w",
  date_iso("<2026-05-06 Wed 10:00 ++1w>") == "2026-05-06T10:00",
  tostring(date_iso("<2026-05-06 Wed 10:00 ++1w>"))
)
check(
  "repeater .+1m",
  date_iso("<2026-05-06 Wed 10:00 .+1m>") == "2026-05-06T10:00",
  tostring(date_iso("<2026-05-06 Wed 10:00 .+1m>"))
)

-- Warning suffix (`-1d`, `--1d`).
check(
  "warning -1d",
  date_iso("<2026-05-06 Wed 10:00 -1d>") == "2026-05-06T10:00",
  tostring(date_iso("<2026-05-06 Wed 10:00 -1d>"))
)
check(
  "warning --2d",
  date_iso("<2026-05-06 Wed 10:00 --2d>") == "2026-05-06T10:00",
  tostring(date_iso("<2026-05-06 Wed 10:00 --2d>"))
)

-- Repeater AND warning together (Emacs supports both).
check(
  "repeater + warning",
  date_iso("<2026-05-06 Wed 10:00 +1w -2d>") == "2026-05-06T10:00",
  tostring(date_iso("<2026-05-06 Wed 10:00 +1w -2d>"))
)

-- Time range `HH:MM-HH:MM` — extract start time only.
check(
  "time range",
  date_iso("<2026-05-06 Wed 10:00-12:30>") == "2026-05-06T10:00",
  tostring(date_iso("<2026-05-06 Wed 10:00-12:30>"))
)

-- Inactive bracket `[...]`.
check(
  "inactive timestamp",
  date_iso("[2026-05-06 Wed 10:00]") == "2026-05-06T10:00",
  tostring(date_iso("[2026-05-06 Wed 10:00]"))
)

-- Non-ASCII day-of-week labels (Japanese / locale-translated Emacs).
check(
  "Japanese day-of-week label",
  date_iso("<2026-05-06 水 10:00>") == "2026-05-06T10:00",
  tostring(date_iso("<2026-05-06 水 10:00>"))
)

-- Malformed inputs — must NOT throw, return nil.
check("nil input", date_iso(nil) == nil)
check("empty input", date_iso("") == nil)
check("garbage input", date_iso("not a timestamp") == nil)
check("partial date (no day)", date_iso("<2026-05>") == nil)

-- parse_ts_body shape sanity.
local p = parse("<2026-05-06 Wed 10:00>")
check("parse: date field", p and p.date == "2026-05-06")
check("parse: time field", p and p.time == "10:00")

local p2 = parse("<2026-05-06>")
check("parse: date-only date field", p2 and p2.date == "2026-05-06")
check("parse: date-only time field is nil", p2 and p2.time == nil)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("timestamp_parity_test: PASS")
