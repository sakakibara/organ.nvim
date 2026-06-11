-- Date parsing for query filters: ISO strings, relative strings, and Unix timestamps.

local M = {}

-- Override point for tests.
M._now = os.time

-- Date input parsing. Accepts:
--   ISO string:          "2024-01-15" or "2024-01-15T14:00"  (pass-through)
--   Relative string:     "today", "+7d", "-1w", "+1m", "+1y"
--   Unix timestamp:      a number
-- Returns an ISO string ("YYYY-MM-DD" or "YYYY-MM-DDTHH:MM"), or nil for
-- unparseable / nil inputs.
function M.parse_date(input)
  if input == nil then
    return nil
  end

  if type(input) == "number" then
    return os.date("!%Y-%m-%d", input)
  end

  if type(input) ~= "string" then
    return nil
  end

  -- ISO passthrough
  if input:match("^%d%d%d%d%-%d%d%-%d%d$") then
    return input
  end
  if input:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d$") then
    return input
  end

  -- "today"
  if input == "today" then
    local t = os.date("*t", M._now())
    return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
  end

  -- Relative: "+7d", "-1w", "+1m", "+1y"
  local sign, n, unit = input:match("^([+-])(%d+)([dwmy])$")
  if sign and n and unit then
    n = tonumber(n)
    if sign == "-" then
      n = -n
    end
    local t = os.date("*t", M._now())
    if unit == "d" then
      t.day = t.day + n
    elseif unit == "w" then
      t.day = t.day + n * 7
    elseif unit == "m" then
      t.month = t.month + n
    elseif unit == "y" then
      t.year = t.year + n
    end
    local norm = os.date("*t", os.time(t))
    return string.format("%04d-%02d-%02d", norm.year, norm.month, norm.day)
  end

  return nil
end

return M
