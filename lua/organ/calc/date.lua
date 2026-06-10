-- Date / time. Stored internally as days since 1970-01-01 (Unix epoch
-- date) for the date part, plus an optional fractional-day component
-- for time. Conversion uses Howard Hinnant's proleptic-Gregorian
-- algorithm, which works for all years (no Y2K-style limits).
--
-- Calc values: { kind = "date", days = N } or
--              { kind = "date", days = N, frac = 0..1 } for datetimes.

local M = {}
local core = require("organ.calc.core")
local bn = require("organ.calc.bn")

local function _is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local function days_from_civil(y, m, d)
  -- Hinnant: shifts month so March = 1, then computes days from a
  -- 400-year era starting at 0000-03-01.
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor((y >= 0 and y or y - 399) / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468 -- offset so 1970-01-01 = 0
end

local function civil_from_days(z)
  z = z + 719468
  local era = math.floor((z >= 0 and z or z - 146096) / 146097)
  local doe = z - era * 146097
  local yoe = math.floor(
    (doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365
  )
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  y = y + (m <= 2 and 1 or 0)
  return y, m, d
end

local function is_date(v)
  return type(v) == "table" and v.kind == "date"
end
function M.is_date(v)
  return is_date(v)
end

function M.date(y, m, d)
  if not (y and m and d) then
    error("calc.date: y, m, d required")
  end
  if m < 1 or m > 12 then
    error("calc.date: month out of range")
  end
  return { kind = "date", days = days_from_civil(y, m, d) }
end

function M.date_from_string(s)
  -- ISO 8601 date: YYYY-MM-DD, optionally with T...
  local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not y then
    error("calc.date_from_string: bad ISO format: " .. s)
  end
  return M.date(tonumber(y), tonumber(m), tonumber(d))
end

function M.date_to_string(v)
  if not is_date(v) then
    error("calc.date_to_string: date required")
  end
  local y, m, d = civil_from_days(v.days)
  return string.format("%04d-%02d-%02d", y, m, d)
end

function M.date_year(v)
  return ({ civil_from_days(v.days) })[1]
end
function M.date_month(v)
  return ({ civil_from_days(v.days) })[2]
end
function M.date_day(v)
  return ({ civil_from_days(v.days) })[3]
end

-- 0 = Sunday, 1 = Monday, ..., 6 = Saturday.
function M.date_weekday(v)
  if not is_date(v) then
    error("calc.date_weekday: date required")
  end
  return (v.days + 4) % 7 -- 1970-01-01 was a Thursday -> +4 to align Sun=0
end

local function _to_int_lua(n)
  if type(n) == "number" then
    return math.floor(n)
  end
  if core.is_int(n) then
    return tonumber(bn.to_string(n.n))
  end
  if core._is_rat(n) then
    return math.floor(core.to_number(n))
  end
  if core.is_float(n) then
    return math.floor(n.v)
  end
  error("calc.date_add: integer days required")
end

function M.date_add_days(d, n)
  if not is_date(d) then
    error("calc.date_add_days: date required")
  end
  return { kind = "date", days = d.days + _to_int_lua(n) }
end

function M.date_sub_days(d, n)
  return M.date_add_days(d, -_to_int_lua(n))
end

-- Difference a - b in (integer) days.
function M.date_diff(a, b)
  if not (is_date(a) and is_date(b)) then
    error("calc.date_diff: two dates required")
  end
  return core.from_int(a.days - b.days)
end

function M.date_cmp(a, b)
  if not (is_date(a) and is_date(b)) then
    error("calc.date_cmp: two dates required")
  end
  if a.days < b.days then
    return -1
  end
  if a.days > b.days then
    return 1
  end
  return 0
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function M.date_add_months(d, n)
  if not is_date(d) then
    error("calc.date_add_months: date required")
  end
  local y, m, day = civil_from_days(d.days)
  local total = m + _to_int_lua(n) - 1
  local years_offset = math.floor(total / 12)
  local new_m = (total % 12) + 1
  local new_y = y + years_offset
  -- Clamp day to last-day-of-target-month if overflow.
  local last_day = DAYS_IN_MONTH[new_m] or 31
  if new_m == 2 and _is_leap(new_y) then
    last_day = 29
  end
  if day > last_day then
    day = last_day
  end
  return M.date(new_y, new_m, day)
end

function M.date_today()
  -- Use os.date if available; falls back to Unix-epoch days via os.time.
  local t = os.date("*t")
  return M.date(t.year, t.month, t.day)
end

return M
