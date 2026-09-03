-- Repeater date math for organ.nvim toggle.

local M = {}

-- Day-of-week labels in Emacs's order (Sunday..Saturday); os.date("%w") returns
-- 0..6 with 0 = Sunday.
local DOW = { [0] = "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function parse_ymd(s)
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  return tonumber(y), tonumber(m), tonumber(d)
end

local function date_table(y, m, d)
  return { year = y, month = m, day = d, hour = 12 } -- noon to dodge DST
end

local function fmt_ymd(t)
  return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

local function dow_of(y, m, d)
  return DOW[tonumber(os.date("%w", os.time(date_table(y, m, d))))]
end

local function days_in_month(y, m)
  local last = os.time({ year = y, month = m + 1, day = 0, hour = 12 })
  return tonumber(os.date("%d", last))
end

-- Add `n` of `unit` to a date.  Month and year steps rely on mktime
-- normalisation, so a day past the end of the target month overflows into
-- the next one exactly like Emacs `encode-time` (Jan 31 +1m -> Mar 3).
-- With `clamp` the day is capped at the target month's length instead, so
-- a skip filter such as `[eom]` searches from the intended month.
local function add_unit(y, m, d, n, unit, clamp)
  if unit == "d" then
    local t = os.time(date_table(y, m, d)) + n * 86400
    local dt = os.date("*t", t)
    return dt.year, dt.month, dt.day
  end
  if unit == "w" then
    return add_unit(y, m, d, n * 7, "d")
  end
  local ty, tm
  if unit == "m" then
    local dt = os.date("*t", os.time({ year = y, month = m + n, day = 1, hour = 12 }))
    ty, tm = dt.year, dt.month
  elseif unit == "y" then
    ty, tm = y + n, m
  else
    error("unknown unit: " .. tostring(unit))
  end
  if clamp then
    d = math.min(d, days_in_month(ty, tm))
  end
  local dt = os.date("*t", os.time({ year = ty, month = tm, day = d, hour = 12 }))
  return dt.year, dt.month, dt.day
end

-- Split "YYYY-MM-DD" or "YYYY-MM-DD HH:MM" into numeric fields; a missing
-- time reads as midnight.
local function parse_now(s)
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  local hh, mi = s:match("^%d%d%d%d%-%d%d%-%d%d%s+(%d%d?):(%d%d)$")
  return tonumber(y), tonumber(m), tonumber(d), tonumber(hh) or 0, tonumber(mi) or 0
end

-- Shift the leading HH:MM of `suffix` (and a HH:MM range end, if any) by
-- `shift_min` minutes, rolling the date through mktime.
local function shift_time(y, m, d, suffix, shift_min)
  local hh, mi, rest = suffix:match("^ (%d%d?):(%d%d)(.*)$")
  local dt = os.date(
    "*t",
    os.time({ year = y, month = m, day = d, hour = tonumber(hh), min = tonumber(mi) + shift_min })
  )
  local out = string.format(" %02d:%02d", dt.hour, dt.min)
  local eh, em, tail = rest:match("^%-(%d%d?):(%d%d)(.*)$")
  if eh then
    local e = (tonumber(eh) * 60 + tonumber(em) + shift_min) % 1440
    out = out .. string.format("-%02d:%02d%s", math.floor(e / 60), e % 60, tail)
  else
    out = out .. rest
  end
  return dt.year, dt.month, dt.day, out
end

local function date_lt(y1, m1, d1, y2, m2, d2)
  if y1 ~= y2 then
    return y1 < y2
  end
  if m1 ~= m2 then
    return m1 < m2
  end
  return d1 < d2
end

-- Two patterns: one for active timestamps (<...>) and one for inactive ([...]).
-- Active suffix may contain a [filter] block, so we allow anything except '>'.
local TS_RE_ACTIVE = "^(<)(%d%d%d%d%-%d%d%-%d%d) (%a%a%a)( ?[^>]*)(>)$"
-- Inactive suffix stops at the first ']' (the timestamp close bracket).
local TS_RE_INACTIVE = "^(%[)(%d%d%d%d%-%d%d%-%d%d) (%a%a%a)( ?[^%]]*)(])$"
local REP_RE = "([%+%.][%+]?)(%d+)([hdwmy])"
-- Two-period habit syntax: `.+1d/3d` means "every 1 day; alarm if not done
-- within 3 days".  Per Emacs `org-habit`.  The `/Nu` half is preserved for
-- round-trip but doesn't change bump semantics.
local DEADLINE_RE = "/(%d+)([hdwmy])"
local FILTER_RE = "%[([^%]]+)%]"

local function match_repeater(suffix)
  local kind, value, unit = suffix:match(REP_RE)
  if not kind then
    return nil
  end
  value = tonumber(value)
  if value == 0 then
    return nil
  end
  return kind, value, unit
end

local function match_ts(s)
  local a, b, c, d, e = s:match(TS_RE_ACTIVE)
  if a then
    return a, b, c, d, e
  end
  return s:match(TS_RE_INACTIVE)
end

function M.parse(timestamp_text)
  local _, _, _, suffix = match_ts(timestamp_text)
  if not suffix or suffix == "" then
    return nil
  end
  local kind, value, unit = match_repeater(suffix)
  if not kind then
    return nil
  end
  local filter = suffix:match(FILTER_RE)
  -- Habit-style alarm period: `.+P/Q` — Emacs `org-habit` syntax meaning
  -- "repeat every P, but flag overdue if more than Q has passed".  We
  -- preserve the parsed components; bump semantics use only the P part.
  local deadline_value, deadline_unit = suffix:match(DEADLINE_RE)
  return {
    kind = kind,
    value = value,
    unit = unit,
    filter = filter,
    deadline_value = deadline_value and tonumber(deadline_value) or nil,
    deadline_unit = deadline_unit,
  }
end

local DOW_INDEX = {
  sun = 0,
  mon = 1,
  tue = 2,
  wed = 3,
  thu = 4,
  fri = 5,
  sat = 6,
}

local MONTH_INDEX = {
  jan = 1,
  feb = 2,
  mar = 3,
  apr = 4,
  may = 5,
  jun = 6,
  jul = 7,
  aug = 8,
  sep = 9,
  oct = 10,
  nov = 11,
  dec = 12,
}

-- Split a value list on `;` (OR within a single token's value).
local function split_or(value)
  local out = {}
  for v in value:gmatch("[^;]+") do
    out[#out + 1] = v:gsub("^%s+", ""):gsub("%s+$", "")
  end
  return out
end

-- Parse "K" component of `nth:K:DOW`.  K may be 1..5 or "last".
local function parse_nth_k(s)
  if s == "last" then
    return -1
  end
  local n = tonumber(s)
  if n and n >= 1 and n <= 5 then
    return n
  end
  return nil
end

-- Helpers that report which date matches a structural rule.

local function is_nth_dow_in_month(y, m, d, k, dow)
  -- k > 0: kth occurrence of `dow` in month (1=first, …, 5=fifth).
  -- k == -1: last occurrence.
  local target_dow = DOW_INDEX[dow]
  if not target_dow then
    return false
  end
  local this_dow = tonumber(os.date("%w", os.time(date_table(y, m, d))))
  if this_dow ~= target_dow then
    return false
  end
  if k == -1 then
    -- Last occurrence: there must be no further `dow` after this date in the month.
    return (d + 7) > days_in_month(y, m)
  else
    -- Kth occurrence: index = floor((d - 1) / 7) + 1.
    return math.floor((d - 1) / 7) + 1 == k
  end
end

-- Map a date to its 1-based business-day index within the month, where a
-- "business day" is a weekday (Mon-Fri) that the calendar resolver does
-- NOT mark as a holiday.  Returns nil if today is not a business day.
local function bizday_index_in_month(y, m, d, calendar_resolver, holiday_cal)
  local target_dow = tonumber(os.date("%w", os.time(date_table(y, m, d))))
  if target_dow == 0 or target_dow == 6 then
    return nil
  end
  if holiday_cal and calendar_resolver(holiday_cal, fmt_ymd({ year = y, month = m, day = d })) then
    return nil
  end
  local idx = 0
  for day = 1, d do
    local dow = tonumber(os.date("%w", os.time(date_table(y, m, day))))
    local is_weekday = (dow >= 1 and dow <= 5)
    local is_holiday = holiday_cal
        and calendar_resolver(holiday_cal, fmt_ymd({ year = y, month = m, day = day }))
      or false
    if is_weekday and not is_holiday then
      idx = idx + 1
    end
  end
  return idx
end

local function bizdays_in_month(y, m, calendar_resolver, holiday_cal)
  local total = 0
  local last = days_in_month(y, m)
  for day = 1, last do
    local dow = tonumber(os.date("%w", os.time(date_table(y, m, day))))
    local is_weekday = (dow >= 1 and dow <= 5)
    local is_holiday = holiday_cal
        and calendar_resolver(holiday_cal, fmt_ymd({ year = y, month = m, day = day }))
      or false
    if is_weekday and not is_holiday then
      total = total + 1
    end
  end
  return total
end

-- Evaluate a single (non-negated) token against a date.  Returns true /
-- false / nil where nil means "unrecognised token" (caller decides
-- whether that is an error or a no-op).
local function token_matches(
  token,
  y,
  m,
  d,
  dow_num,
  last_day,
  date_str,
  calendar_resolver,
  holiday_cal
)
  -- Whole-token shortcuts.
  if token == "wd" then
    return dow_num >= 1 and dow_num <= 5
  end
  if token == "we" then
    return dow_num == 0 or dow_num == 6
  end
  if token == "bom" or token == "first" then
    return d == 1
  end
  if token == "eom" or token == "last" then
    return d == last_day
  end
  if token == "bizday" then
    local idx = bizday_index_in_month(y, m, d, calendar_resolver, holiday_cal)
    return idx ~= nil
  end

  -- Named day (mon/tue/...): exact dow match.
  if DOW_INDEX[token] ~= nil then
    return dow_num == DOW_INDEX[token]
  end
  -- Named month (jan/feb/...): exact month match.
  if MONTH_INDEX[token] ~= nil then
    return m == MONTH_INDEX[token]
  end

  -- KEY:VALUE tokens.
  local key, rest = token:match("^([%w_]+):(.+)$")
  if not key then
    return nil
  end

  -- `cal:NAME`
  if key == "cal" then
    return calendar_resolver(rest, date_str)
  end

  -- Tokens whose VALUE is a `;`-separated OR list of atoms (or signed ints).
  if key == "dom" then
    for _, v in ipairs(split_or(rest)) do
      if v == "first" and d == 1 then
        return true
      end
      if v == "last" and d == last_day then
        return true
      end
      local n = tonumber(v)
      if n then
        if n > 0 and d == n then
          return true
        end
        if n < 0 and d == last_day + n + 1 then
          return true
        end
        -- e.g. -1 → last_day; -3 → last_day - 2 (the third-from-last day,
        -- iCal-style).  Users wanting "exactly 3 days before last day"
        -- can write `dom:-4`.
      end
    end
    return false
  end

  if key == "month" then
    for _, v in ipairs(split_or(rest)) do
      local n = tonumber(v)
      if n and m == n then
        return true
      end
      if MONTH_INDEX[v] and m == MONTH_INDEX[v] then
        return true
      end
    end
    return false
  end

  if key == "quarter" then
    -- VALUE is one or more ints in [1,4] (`;`-separated).
    for _, v in ipairs(split_or(rest)) do
      local n = tonumber(v)
      if n and n >= 1 and n <= 4 then
        local q_first = (n - 1) * 3 + 1
        if m >= q_first and m <= q_first + 2 then
          return true
        end
      end
    end
    return false
  end

  if key == "nth" then
    -- VALUE: `K:DOW` or `K:DOW1;DOW2;…`
    local k_str, dow_part = rest:match("^([%w_]+):(.+)$")
    if not k_str then
      return false
    end
    local k = parse_nth_k(k_str)
    if not k then
      return false
    end
    for _, dow_name in ipairs(split_or(dow_part)) do
      if is_nth_dow_in_month(y, m, d, k, dow_name) then
        return true
      end
    end
    return false
  end

  if key == "bizday" then
    -- `bizday:N` or `bizday:-N` (one int, optionally `;`-separated OR list).
    local idx = bizday_index_in_month(y, m, d, calendar_resolver, holiday_cal)
    if not idx then
      return false
    end
    local total = bizdays_in_month(y, m, calendar_resolver, holiday_cal)
    for _, v in ipairs(split_or(rest)) do
      local n = tonumber(v)
      if n then
        if n > 0 and idx == n then
          return true
        end
        if n < 0 and idx == total + n + 1 then
          return true
        end
      end
    end
    return false
  end

  return nil
end

-- Resolve a filter for a date. Returns true iff the date passes the filter.
--
-- Two-tier semantics (existing):
--   • Bare named-day / named-month tokens are OR-combined within their
--     class: the date must match at least one of the listed names.
--     Example `[mon,wed,fri]` (any of) or `[jan,apr,jul,oct]` (any of).
--   • Every other (positive or negated) token is AND-combined.  Within
--     a single `KEY:VALUE` token, the VALUE may be a `;`-separated OR
--     list — e.g. `dom:1;15;25` means "day 1 or 15 or 25".
--
-- Token vocabulary:
--   wd, we                                  weekday / weekend class
--   mon..sun                                named day (OR within filter)
--   jan..dec                                named month (OR within filter)
--   bom, first                              day-of-month is 1
--   eom, last                               day-of-month is last day of month
--   bizday                                  weekday and not in holiday cal
--   dom:N                                   exact day of month (1..31)
--   dom:-N                                  Nth from end (-1 = last day)
--   dom:first|last                          aliases for dom:1 / dom:-1
--   dom:N1;N2;...                           any of these days
--   nth:K:DOW                               Kth weekday in month (K = 1..5 or "last")
--   nth:K:DOW1;DOW2;...                     Kth of any listed DOW
--   month:N                                 month is N (1..12)
--   month:NAME                              month by short name (jan..dec)
--   month:V1;V2;...                         any of these months
--   quarter:Q                               month falls in quarter Q (1..4)
--   quarter:Q1;Q2;...                       any of these quarters
--   bizday:N                                Nth business day of month
--   bizday:-N                               Nth business day from end
--   bizday:N1;N2;...                        any of these
--   cal:NAME                                in calendar NAME (e.g. cal:US)
--   !TOKEN                                  negation of any of the above
local function date_passes_filter(filter, y, m, d, calendar_resolver, holiday_cal)
  if filter == nil or filter == "" then
    return true
  end
  local dow_num = tonumber(os.date("%w", os.time(date_table(y, m, d))))
  local last_day = days_in_month(y, m)
  local date_str = fmt_ymd({ year = y, month = m, day = d })

  -- Collect bare named-day / named-month tokens for OR-combination.
  -- Other tokens (class, KEY:VALUE, negations, calendars) are AND-combined.
  local named_days = {}
  local has_named_days = false
  local named_months = {}
  local has_named_months = false

  for token in filter:gmatch("[^,]+") do
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    local negate = token:sub(1, 1) == "!"
    if negate then
      token = token:sub(2)
    end

    if not negate and DOW_INDEX[token] ~= nil and token ~= "wd" and token ~= "we" then
      named_days[#named_days + 1] = DOW_INDEX[token]
      has_named_days = true
    elseif not negate and MONTH_INDEX[token] ~= nil then
      named_months[#named_months + 1] = MONTH_INDEX[token]
      has_named_months = true
    else
      local matched =
        token_matches(token, y, m, d, dow_num, last_day, date_str, calendar_resolver, holiday_cal)
      if matched == nil then
        return false
      end -- unknown token
      if negate then
        matched = not matched
      end
      if not matched then
        return false
      end
    end
  end

  if has_named_days then
    local ok = false
    for _, idx in ipairs(named_days) do
      if dow_num == idx then
        ok = true
        break
      end
    end
    if not ok then
      return false
    end
  end
  if has_named_months then
    local ok = false
    for _, idx in ipairs(named_months) do
      if m == idx then
        ok = true
        break
      end
    end
    if not ok then
      return false
    end
  end

  return true
end

-- Default calendar resolver. Tests can swap M._test_calendar to inject behavior.
local function resolve_calendar(name, date)
  if M._test_calendar then
    return M._test_calendar(name, date)
  end
  -- Real implementation lives in lua/organ/holidays.lua; loaded lazily.
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config or not require("organ.buf_config").read(nil, "todo") then
    return false
  end
  local user_cals = require("organ.buf_config").read(nil, "todo.calendars") or {}
  local cal = user_cals[name]
  if cal then
    if type(cal) == "function" then
      local ok2, res = pcall(cal, date)
      return ok2 and res or false
    end
    if type(cal) == "table" then
      for _, d in ipairs(cal) do
        if d == date then
          return true
        end
      end
      return false
    end
  end
  -- ISO 3166-1 alpha-2 country: route to holidays module.
  if name:match("^[A-Z][A-Z]$") then
    local ok2, hol = pcall(require, "organ.holidays")
    if ok2 then
      return hol.is_holiday(name, date)
    end
  end
  return false
end

-- Shift a repeating timestamp past `now` ("YYYY-MM-DD" or "YYYY-MM-DD
-- HH:MM") the way `org-auto-repeat-maybe` does.  Returns the new timestamp
-- text, or nil plus an error message.
function M.bump(timestamp_text, now)
  local open_b, ymd, _, suffix, close_b = match_ts(timestamp_text)
  if not open_b then
    return nil, "not a recognised timestamp"
  end
  local kind, value, unit = match_repeater(suffix)
  if not kind then
    return nil, "no repeater in timestamp"
  end
  local filter = suffix:match(FILTER_RE)

  local oy, om, od = parse_ymd(ymd)
  local ny, nm, nd, nh, nmin = parse_now(now)
  local by, bm, bd

  if unit == "h" then
    local hh, mi = suffix:match("^ (%d%d?):(%d%d)")
    if not hh then
      return nil, string.format("Cannot repeat in %d hour(s) because no hour has been set", value)
    end
    hh, mi = tonumber(hh), tonumber(mi)
    local function shifted(min)
      return os.time({ year = oy, month = om, day = od, hour = hh, min = mi + min })
    end
    local now_t = os.time({ year = ny, month = nm, day = nd, hour = nh, min = nmin })
    local shift_min
    if kind == "+" then
      shift_min = value * 60
    elseif kind == "++" then
      local steps = math.floor((now_t - shifted(0)) / (value * 3600))
      shift_min = math.max(1, steps - 1) * value * 60
      while shifted(shift_min) <= now_t do
        shift_min = shift_min + value * 60
      end
    elseif kind == ".+" then
      shift_min = math.floor((now_t - shifted(0)) / 60) + value * 60
    else
      return nil, "unknown repeater kind: " .. kind
    end
    by, bm, bd, suffix = shift_time(oy, om, od, suffix, shift_min)
  elseif kind == "+" then
    by, bm, bd = add_unit(oy, om, od, value, unit, filter ~= nil)
  elseif kind == "++" then
    by, bm, bd = oy, om, od
    for _ = 1, 366 do
      by, bm, bd = add_unit(by, bm, bd, value, unit, filter ~= nil)
      if not date_lt(by, bm, bd, ny, nm, nd) and not (by == ny and bm == nm and bd == nd) then
        break
      end
    end
  elseif kind == ".+" then
    by, bm, bd = add_unit(ny, nm, nd, value, unit, filter ~= nil)
  else
    return nil, "unknown repeater kind: " .. kind
  end

  -- Apply skip filter: advance one day at a time until satisfied.
  if filter then
    -- Default holiday calendar comes from organ.config.todo.default_holiday_cal,
    -- if any.  Used by `bizday` and `bizday:N` tokens (skipping holidays as well
    -- as weekends).  Users can also write `[bizday,!cal:US]` explicitly.
    local default_holiday_cal = nil
    local ok, organ = pcall(require, "organ")
    if ok and organ.config and require("organ.buf_config").read(nil, "todo") then
      default_holiday_cal = require("organ.buf_config").read(nil, "todo.default_holiday_cal")
    end
    local hit = false
    -- Bizday-aware filters can require iterating well beyond 366 days
    -- in pathological cases (e.g. nth:5:fri rare months); cap at 4
    -- years.  An impossible filter is still bounded.
    for _ = 1, 366 * 4 do
      if date_passes_filter(filter, by, bm, bd, resolve_calendar, default_holiday_cal) then
        hit = true
        break
      end
      by, bm, bd = add_unit(by, bm, bd, 1, "d")
    end
    if not hit then
      return nil, "repeater skip filter is impossible: " .. filter
    end
  end

  local new_dow = dow_of(by, bm, bd)
  return string.format(
    "%s%s %s%s%s",
    open_b,
    fmt_ymd({ year = by, month = bm, day = bd }),
    new_dow,
    suffix,
    close_b
  )
end

return M
