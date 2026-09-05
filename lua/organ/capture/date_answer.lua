-- Parse an answer typed at the `%^t`-family capture date prompt.
--
-- The accepted forms are the ones the org manual documents for the
-- date/time prompt: absolute dates, month and weekday names, ISO week
-- dates, relative offsets, clock times and time ranges.  An answer
-- matching none of them yields nil so the caller can report it instead
-- of writing a date that merely looks right.

local M = {}

local DAY = 86400

local MONTHS = {
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
  january = 1,
  february = 2,
  march = 3,
  april = 4,
  june = 6,
  july = 7,
  august = 8,
  september = 9,
  october = 10,
  november = 11,
  december = 12,
}

local WEEKDAYS = {
  sun = 0,
  mon = 1,
  tue = 2,
  wed = 3,
  thu = 4,
  fri = 5,
  sat = 6,
  sunday = 0,
  monday = 1,
  tuesday = 2,
  wednesday = 3,
  thursday = 4,
  friday = 5,
  saturday = 6,
}

local OFFSET_UNITS = { d = "day", w = "week", m = "month", y = "year", h = "hour" }

local function full_year(n, digits)
  if digits > 2 then
    return n
  end
  return n < 69 and 2000 + n or 1900 + n
end

local function weekday_of(y, m, d)
  return os.date("*t", os.time({ year = y, month = m, day = d, hour = 12 })).wday - 1
end

-- Calendar date of ISO weekday `dow` (1 = Monday ... 7 = Sunday) in ISO
-- week `week` of `year`.  January 4 always falls in ISO week 1.
local function iso_week_date(year, week, dow)
  local jan4 = os.time({ year = year, month = 1, day = 4, hour = 12 })
  if not jan4 then
    return nil
  end
  local jan4_dow = (os.date("*t", jan4).wday + 5) % 7 + 1
  local t = os.date("*t", jan4 + ((week - 1) * 7 + dow - jan4_dow) * DAY)
  return t.year, t.month, t.day
end

local function meridiem(hour, ap)
  if ap == "am" then
    return hour % 12
  elseif ap == "pm" then
    return hour % 12 + 12
  end
  return hour
end

-- One clock reading: `9:30`, `9:30pm`, `9pm`, `9h`, `9h30`.
local function clock(tok)
  local h, mi, ap = tok:match("^(%d+):(%d%d)([ap]m)$")
  if h then
    return meridiem(tonumber(h), ap), tonumber(mi)
  end
  h, mi = tok:match("^(%d+):(%d%d)$")
  if h then
    return tonumber(h), tonumber(mi)
  end
  h, ap = tok:match("^(%d+)([ap]m)$")
  if h then
    return meridiem(tonumber(h), ap), 0
  end
  h, mi = tok:match("^(%d+)h(%d%d)$")
  if h then
    return tonumber(h), tonumber(mi)
  end
  h = tok:match("^(%d+)h$")
  if h then
    return tonumber(h), 0
  end
  return nil
end

-- A clock reading, a `-`/`--` separated range, or a start plus a
-- `+HH:MM` duration.  Returns start hour, start minute, end hour, end
-- minute.
local function time_spec(tok)
  local from, to = tok:match("^(.-)%-%-?(.+)$")
  if from then
    local h, mi = clock(from)
    local eh, emi = clock(to)
    if h and eh then
      return h, mi, eh, emi
    end
    return nil
  end
  local dur
  from, dur = tok:match("^(.-)%+(.+)$")
  if from then
    local h, mi = clock(from)
    local dh, dmi = dur:match("^(%d+):(%d%d)$")
    if h and dh then
      local total = h * 60 + mi + tonumber(dh) * 60 + tonumber(dmi)
      return h, mi, math.floor(total / 60) % 24, total % 60
    end
    return nil
  end
  local h, mi = clock(tok)
  if h then
    return h, mi
  end
  return nil
end

-- An absolute date: `20260915`, `2026-09-15` (year first), `9/15/2026`
-- (year last), `9-15` and `9/15` (no year).  Returns year (nil when
-- absent), month, day.
local function date_spec(tok)
  local y, m, d = tok:match("^(%d%d%d%d)(%d%d)(%d%d)$")
  if y then
    return tonumber(y), tonumber(m), tonumber(d)
  end
  local a, b, c = tok:match("^(%d+)%-(%d+)%-(%d+)$")
  if a then
    return full_year(tonumber(a), #a), tonumber(b), tonumber(c)
  end
  a, b, c = tok:match("^(%d+)/(%d+)/(%d+)$")
  if a then
    return full_year(tonumber(c), #c), tonumber(a), tonumber(b)
  end
  a, b, c = tok:match("^(%d+)%.(%d+)%.(%d+)$")
  if a then
    return full_year(tonumber(c), #c), tonumber(b), tonumber(a)
  end
  a, b = tok:match("^(%d+)%.(%d+)%.?$")
  if a then
    a, b = tonumber(a), tonumber(b)
    if a >= 1 and a <= 31 and b >= 1 and b <= 12 then
      return nil, b, a
    end
  end
  a, b = tok:match("^(%d+)[-/](%d+)$")
  if a then
    a, b = tonumber(a), tonumber(b)
    if a >= 1 and a <= 12 and b >= 1 and b <= 31 then
      return nil, a, b
    end
  end
  return nil
end

-- `w36`, `w36-3`, `2026-w36`, `2026-w36-3`.  Returns year (nil when
-- absent), week, ISO weekday (nil when absent).
local function week_spec(tok)
  local y, w, d = tok:match("^(%d+)%-w(%d+)%-?(%d*)$")
  if not y then
    w, d = tok:match("^w(%d+)%-?(%d*)$")
    if not w then
      return nil
    end
  end
  d = tonumber(d)
  if d and (d < 0 or d > 7) then
    return nil
  end
  if d == 0 then
    d = 7
  end
  return y and full_year(tonumber(y), #y), tonumber(w), d
end

-- Leading `+`/`-`/`++`/`--` offset: a count plus either a unit letter
-- (d, w, m, y, h) or a weekday name.  A bare sign means one day.
local function offset_spec(tok)
  local sign, count, word = tok:match("^([+-][+-]?)(%d*)(%a*)$")
  if not sign then
    return nil
  end
  local n = tonumber(count) or 1
  local dir = sign:sub(1, 1) == "-" and -1 or 1
  if word == "" then
    return { unit = "day", n = n * dir }
  end
  if OFFSET_UNITS[word] then
    return { unit = OFFSET_UNITS[word], n = n * dir }
  end
  if WEEKDAYS[word] then
    return { unit = "weekday", weekday = WEEKDAYS[word], n = math.max(n, 1), dir = dir }
  end
  return nil
end

-- Classify the whitespace-separated tokens of an answer.  Returns nil
-- as soon as one token is unrecognised or repeats a field.
local function classify(tokens)
  local f = { nums = {} }
  local function set(key, value)
    if f[key] ~= nil then
      return false
    end
    f[key] = value
    return true
  end
  for _, tok in ipairs(tokens) do
    local wy, week, wdow = week_spec(tok)
    local y, m, d = date_spec(tok)
    local h, mi, eh, emi = time_spec(tok)
    if week then
      if not set("week", week) then
        return nil
      end
      f.week_year, f.week_dow = wy, wdow
    elseif m then
      if not set("month", m) or not set("day", d) then
        return nil
      end
      f.year, f.year_given = y, y ~= nil
    elseif MONTHS[tok] then
      if not set("month_name", MONTHS[tok]) then
        return nil
      end
    elseif WEEKDAYS[tok] then
      if not set("weekday", WEEKDAYS[tok]) then
        return nil
      end
    elseif h then
      if not set("hour", h) then
        return nil
      end
      f.min, f.end_hour, f.end_min = mi, eh, emi
    elseif tok:match("^%d+$") then
      f.nums[#f.nums + 1] = { value = tonumber(tok), digits = #tok }
    else
      return nil
    end
  end
  return f
end

-- Turn a date-prompt answer into a concrete time.  Returns
-- { time = <os.time value>, with_time = <bool>, end_hm = <"HH:MM"|nil> }
-- or nil when the answer matches no accepted form.
function M.parse(answer, now)
  local s = vim.trim(answer or "")
  local base = os.date("*t", now)
  local year, month, day = base.year, base.month, base.day
  local hour, min = base.hour, base.min

  if s == "" or s == "." then
    return {
      time = os.time({ year = year, month = month, day = day, hour = hour, min = min, sec = 0 }),
    }
  end

  local tokens = {}
  for tok in s:lower():gmatch("%S+") do
    tokens[#tokens + 1] = tok
  end

  local offset
  if tokens[1]:match("^[+-]") then
    offset = offset_spec(tokens[1])
    if not offset then
      return nil
    end
    table.remove(tokens, 1)
  end

  local f = classify(tokens)
  if not f then
    return nil
  end

  local with_time = f.hour ~= nil
  if with_time then
    hour, min = f.hour, f.min
  end

  local dated = f.week or f.month or f.month_name or f.weekday or #f.nums > 0
  -- Roll a date that has already gone by into the future, as the date
  -- prompt does whenever the year (or the month, for a bare day) was
  -- left out.
  local roll

  if offset then
    if dated then
      return nil
    end
    if offset.unit == "weekday" then
      local delta = (offset.weekday - weekday_of(year, month, day)) * offset.dir % 7
      if delta == 0 then
        delta = 7
      end
      day = day + (delta + (offset.n - 1) * 7) * offset.dir
    elseif offset.unit == "day" then
      day = day + offset.n
    elseif offset.unit == "week" then
      day = day + offset.n * 7
    elseif offset.unit == "month" then
      month = month + offset.n
    elseif offset.unit == "year" then
      year = year + offset.n
    else
      hour = hour + offset.n
      with_time = true
    end
  elseif f.week then
    if f.month_name or f.month or #f.nums > 1 or (f.week_dow and f.weekday) then
      return nil
    end
    local wy = f.week_year
    if not wy and f.nums[1] then
      wy = full_year(f.nums[1].value, f.nums[1].digits)
    end
    local dow = f.week_dow
    if not dow and f.weekday then
      dow = f.weekday == 0 and 7 or f.weekday
    end
    year, month, day = iso_week_date(wy or base.year, f.week, dow or 1)
    if not year then
      return nil
    end
  elseif f.month then
    if f.month_name or f.weekday or #f.nums > 0 then
      return nil
    end
    month, day = f.month, f.day
    if f.year_given then
      year = f.year
    else
      roll = "year"
    end
  elseif f.month_name then
    if f.weekday or #f.nums > 2 then
      return nil
    end
    month = f.month_name
    if f.nums[1] then
      day = f.nums[1].value
    end
    if f.nums[2] then
      year = full_year(f.nums[2].value, f.nums[2].digits)
    else
      roll = "year"
    end
  elseif f.weekday then
    if #f.nums > 0 then
      return nil
    end
    local delta = (f.weekday - weekday_of(year, month, day)) % 7
    day = day + (delta == 0 and 7 or delta)
  elseif #f.nums == 1 then
    local n = f.nums[1]
    if n.value >= 1 and n.value <= 31 then
      day = n.value
      roll = "month"
    else
      year = full_year(n.value, n.digits)
    end
  elseif #f.nums > 1 then
    return nil
  end

  if
    roll
    and (
      year < base.year
      or (year == base.year and (month < base.month or (month == base.month and day < base.day)))
    )
  then
    if roll == "month" then
      month = month + 1
    else
      year = year + 1
    end
  end

  local ok, t =
    pcall(os.time, { year = year, month = month, day = day, hour = hour, min = min, sec = 0 })
  if not ok or not t then
    return nil
  end
  return {
    time = t,
    with_time = with_time,
    end_hm = f.end_hour and string.format("%02d:%02d", f.end_hour, f.end_min),
  }
end

return M
