local M = {}

-- Parse Emacs `:EFFORT:` property values into minutes.
-- Recognised forms:
--   "30"           → 30  (bare integer = minutes)
--   "1:30"         → 90
--   "30m" "30min"  → 30
--   "2h" "2hr"     → 120
--   "1.5h"         → 90
--   "1d"           → 24*60 (calendar day, not workday)
--   "1w"           → 7*24*60
function M.parse(s)
  if type(s) ~= "string" or s == "" then
    return nil
  end
  s = s:match("^%s*(.-)%s*$")
  -- HH:MM
  local h, m = s:match("^(%d+):(%d%d)$")
  if h then
    return tonumber(h) * 60 + tonumber(m)
  end
  -- pure number → minutes
  if s:match("^%d+$") then
    return tonumber(s)
  end
  -- decimal hours like 1.5h
  local total_minutes = 0
  local matched_any = false
  for n, unit in s:gmatch("([%d%.]+)%s*([dhmw][a-z]*)") do
    matched_any = true
    local v = tonumber(n)
    if not v then
      return nil
    end
    if unit:sub(1, 1) == "m" then
      total_minutes = total_minutes + v
    elseif unit:sub(1, 1) == "h" then
      total_minutes = total_minutes + v * 60
    elseif unit:sub(1, 1) == "d" then
      total_minutes = total_minutes + v * 60 * 24
    elseif unit:sub(1, 1) == "w" then
      total_minutes = total_minutes + v * 60 * 24 * 7
    end
  end
  if matched_any then
    return math.floor(total_minutes + 0.5)
  end
  return nil
end

-- Format minutes back into the canonical "H:MM" or "Xm" representation.
-- Caller chooses by `style` ("hm" → 1:30; "compact" → 1h30m or 30m).
function M.format(minutes, style)
  if not minutes then
    return ""
  end
  style = style or "hm"
  if style == "hm" then
    local h = math.floor(minutes / 60)
    local m = minutes % 60
    return string.format("%d:%02d", h, m)
  end
  -- compact
  local h = math.floor(minutes / 60)
  local m = minutes % 60
  if h > 0 and m > 0 then
    return string.format("%dh%dm", h, m)
  end
  if h > 0 then
    return string.format("%dh", h)
  end
  return string.format("%dm", m)
end

-- Sum clock entries belonging to a row. `clock_entries` is a list of
-- { start_ts, end_ts, duration_seconds } records produced by
-- `query.clock_entries({ headline_id = id })`.
function M.clocked_minutes(clock_entries)
  if not clock_entries or #clock_entries == 0 then
    return 0
  end
  local total = 0
  for _, c in ipairs(clock_entries) do
    if c.duration_seconds then
      total = total + c.duration_seconds
    end
  end
  return math.floor(total / 60 + 0.5)
end

-- Read the EFFORT property from a row's `properties` table.
-- Parse an effort filter expression into a predicate fn(minutes) → bool.
--   "<30"           → less than 30 minutes
--   ">=1:00"        → ≥ 60 minutes
--   "1:00..2:00"    → between 60 and 120 minutes inclusive
--   "60"            → exactly 60 minutes
--   ""              → matches everything
-- Returns predicate, or (nil, error_message) on a malformed input.
function M.parse_filter(spec)
  spec = (spec or ""):match("^%s*(.-)%s*$")
  if spec == "" then
    return function()
      return true
    end
  end

  local lo_s, hi_s = spec:match("^(.-)%.%.(.+)$")
  if lo_s and hi_s then
    local lo = M.parse(lo_s)
    local hi = M.parse(hi_s)
    if not lo or not hi then
      return nil, "bad range bounds: " .. spec
    end
    return function(min)
      return min and min >= lo and min <= hi
    end
  end

  local op, val_s = spec:match("^([<>]=?)%s*(.+)$")
  if op then
    local v = M.parse(val_s)
    if not v then
      return nil, "bad value: " .. val_s
    end
    if op == "<" then
      return function(m)
        return m and m < v
      end
    end
    if op == ">" then
      return function(m)
        return m and m > v
      end
    end
    if op == "<=" then
      return function(m)
        return m and m <= v
      end
    end
    if op == ">=" then
      return function(m)
        return m and m >= v
      end
    end
  end

  local v = M.parse(spec)
  if v then
    return function(m)
      return m == v
    end
  end
  return nil, "could not parse: " .. spec
end

function M.row_effort_minutes(row)
  if not row or not row.properties then
    return nil
  end
  local raw = row.properties.EFFORT or row.properties.Effort or row.properties.effort
  return M.parse(raw)
end

return M
