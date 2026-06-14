-- Date/time helpers and deterministic clock override for the agenda.
--
-- Clock reads funnel through now_iso/today_iso/now_ts so the snapshot
-- test (and any other harness that wants a deterministic agenda) can
-- pin "now" via `config.agenda.now_override`.  The override accepts:
--
--   "YYYY-MM-DD"            -> date only; HH:MM derived from os.time()
--                             (use the timestamp form for full
--                             determinism)
--   "YYYY-MM-DDTHH:MM"      -> date + time of day
--
-- Production agenda renders leave it nil and use the wall clock.

local M = {}

local function now_iso()
  local override = (require("organ.buf_config").read(nil, "agenda") or {}).now_override
  if override then
    return override
  end
  return os.date("%Y-%m-%dT%H:%M")
end

local function today_iso()
  return now_iso():sub(1, 10)
end

local function now_ts()
  local override = (require("organ.buf_config").read(nil, "agenda") or {}).now_override
  if not override then
    return os.time()
  end
  local y, mo, d, h, mi = override:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)")
  if not y then
    y, mo, d = override:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    h, mi = "12", "00"
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
  })
end

-- Date-header format mirrors Emacs's `org-agenda-format-date`:
--   "Sunday      3 May 2026" -- full weekday name (left-padded to 9 chars
--   so all weekdays line up), day-of-month with no leading zero, full
--   month name, year.
local WDAY_FULL = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTH_FULL = {
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
}

-- ISO week number per ISO 8601 (week-of-year for date in `t`).
local function iso_week_of(t)
  -- %V = ISO 8601 week number, available on most modern strftime
  -- implementations (Lua 5.1 + LuaJIT use the C library's strftime).
  local w = tonumber(os.date("%V", t))
  if w then
    return w
  end
  -- Defensive fallback: derive via Thursday-of-week trick.
  local wday = tonumber(os.date("%w", t)) -- 0=Sun..6=Sat
  local thurs = t + (4 - (wday == 0 and 7 or wday)) * 86400
  local y0 = tonumber(os.date("%Y", thurs))
  local jan4 = os.time({ year = y0, month = 1, day = 4, hour = 12 })
  return math.floor((thurs - jan4) / (86400 * 7)) + 1
end

-- "2026-05-03" -> "Sunday      3 May 2026 W18".  Day name left-padded
-- to 11 chars (matches Emacs `org-agenda-format-date` default --
-- Wednesday is 9 chars, so the longer names get 2 trailing spaces and
-- the shorter ones pad up; everything aligns at column 13).
local function date_header(iso_date)
  local y, m, d = iso_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return iso_date
  end
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local wday = WDAY_FULL[tonumber(os.date("%w", t)) + 1]
  local month = MONTH_FULL[tonumber(m)]
  return string.format("%-11s %d %s %s W%02d", wday, tonumber(d), month, y, iso_week_of(t))
end

local function date_only(iso)
  if not iso then
    return nil
  end
  return iso:sub(1, 10)
end

-- Returns "9:00" / "23:45" -- no leading zero on the hour, mirroring
-- Emacs's default `org-agenda-time-leading-zero = nil`.
local function time_only(iso)
  if not iso or #iso < 16 then
    return nil
  end
  if iso:sub(11, 11) ~= "T" then
    return nil
  end
  local hh, mm = iso:sub(12, 13), iso:sub(15, 16)
  -- `agenda.time_leading_zero` (Emacs `org-agenda-time-leading-zero`):
  --   false (default) -> strip leading zero  ` 9:00` (compact, Emacs default)
  --   true            -> keep `09:00`        (uniform 5-cell column)
  local lead = (require("organ.buf_config").read(nil, "agenda") or {}).time_leading_zero
  if lead == true then
    return hh .. ":" .. mm
  end
  return tostring(tonumber(hh)) .. ":" .. mm
end

local function date_only_str(iso)
  if type(iso) ~= "string" then
    return nil
  end
  return iso:match("^(%d%d%d%d%-%d%d%-%d%d)")
end

local function iso_to_ts(iso)
  local d = date_only_str(iso)
  if not d then
    return nil
  end
  local y, mo, da = d:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(da),
    hour = 12,
    min = 0,
    sec = 0,
  })
end

local function days_diff(from_iso, to_iso)
  local a, b = iso_to_ts(from_iso), iso_to_ts(to_iso)
  if not a or not b then
    return nil
  end
  return math.floor((b - a) / 86400 + 0.5)
end

-- Add `n` whole days to an ISO date, returning a new "YYYY-MM-DD". Anchors
-- at noon so a DST transition between the two dates cannot land the result
-- on the wrong calendar day. Returns `iso` unchanged when it does not parse.
local function add_days(iso, n)
  local ts = iso_to_ts(iso)
  if not ts then
    return iso
  end
  local t = os.date("*t", ts + n * 86400)
  return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

M.now_iso = now_iso
M.today_iso = today_iso
M.now_ts = now_ts
M.iso_week_of = iso_week_of
M.date_header = date_header
M.date_only = date_only
M.time_only = time_only
M.iso_to_ts = iso_to_ts
M.days_diff = days_diff
M.add_days = add_days

return M
