-- Org's org-duration.el (Emacs 31.1), ported: duration strings to
-- minutes and minutes to duration strings, with org-duration-units and
-- org-duration-format at their defaults.
--
-- A Lua number stands for an Emacs integer or float alike, and the two
-- format differently once doubles lose exactness, so organ answers only
-- below B = 2^53: to_minutes fails with "duration out of range" when the
-- computation forms an integer of B or more (a parsed integer, a product
-- with an integer modifier, 60 * hours, a running integer sum), and
-- from_minutes when |minutes| * 60 >= B.
--
-- A format is nil (the default), "h:mm", "h:mm:ss", or a list standing
-- for Emacs's alist, in order, of:
--   { UNIT, REQUIRED }   (UNIT . REQUIRED), UNIT a string
--   { special = MODE }   (special . MODE), MODE "h:mm", "h:mm:ss", an
--                        integer, or false for nil
--   "compact"            the symbol compact
-- Any other string stands for a symbol of that name.  An empty list is
-- nil, as in Emacs.
--
-- Errors carry Emacs's message: to_minutes and from_minutes return nil
-- and the message.

local ffi = require("ffi")
local reader = require("organ.elisp.reader")

pcall(ffi.cdef, "int snprintf(char *str, size_t size, const char *format, ...);")

local M = {}

local byte = string.byte
local floor = math.floor

local B = 2 ^ 53
local OUT_OF_RANGE = "duration out of range"

local UNITS = { min = 1, h = 60, d = 1440, w = 10080, m = 43200, y = 525960 }
local CANONICAL = { min = 1, h = 60, d = 1440 }
-- Units whose modifier is an Emacs float: (* 60 24 365.25).
local FLOAT_UNIT = { y = true }

local DEFAULT_FORMAT = { { "d", false }, { special = "h:mm" } }

local Failure = {}

local function fail(msg)
  error(setmetatable({ msg = msg }, Failure), 0)
end

local function string_literal(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

-- prin1 of an atom of the format encoding: a string is a symbol.
local function atom_repr(x)
  if type(x) == "string" then
    local V = require("organ.elisp.value")
    return require("organ.elisp").prin1(V.intern(x)).value
  elseif type(x) == "number" then
    if x == floor(x) and math.abs(x) < B then
      return string.format("%d", x)
    end
    return require("organ.elisp.printer").float_string(x)
  elseif x == nil or x == false then
    return "nil"
  elseif x == true then
    return "t"
  end
  error("organ.duration: format holds a " .. type(x), 0)
end

local function modifier(unit, canonical)
  local v = type(unit) == "string" and (canonical and CANONICAL or UNITS)[unit]
  if not v then
    fail("Unknown unit: " .. (type(unit) == "string" and string_literal(unit) or atom_repr(unit)))
  end
  return v, not canonical and FLOAT_UNIT[unit] == true
end

-- Matching: the whitespace class is [ \t], case folds ASCII only.

local function is_digit(c)
  return c ~= nil and c >= 48 and c <= 57
end

local function skip_ws(s, i)
  local c = byte(s, i)
  while c == 32 or c == 9 do
    i = i + 1
    c = byte(s, i)
  end
  return i
end

local function skip_digits(s, i)
  while is_digit(byte(s, i)) do
    i = i + 1
  end
  return i
end

local function fold(c)
  if c and c >= 65 and c <= 90 then
    return c + 32
  end
  return c
end

-- org-duration--unit-re at byte i: number from i to j - 1, unit from k
-- to e - 1.  Greedy is the only way it matches: a shorter number or
-- blank run leaves a digit, dot or blank where the unit must start, and
-- "min" is tried before "m".
local function unit_at(s, i)
  local j = skip_digits(s, i)
  if j == i then
    return nil
  end
  if byte(s, j) == 46 then
    j = skip_digits(s, j + 1)
  end
  local k = skip_ws(s, j)
  local c = fold(byte(s, k))
  if c == 109 and fold(byte(s, k + 1)) == 105 and fold(byte(s, k + 2)) == 110 then
    return j, k, k + 3
  elseif c == 100 or c == 104 or c == 109 or c == 119 or c == 121 then
    return j, k, k + 1
  end
  return nil
end

-- The byte after \(?:[ \t]*UNIT\)+ from i, or nil.
local function units_end(s, i)
  local n = 0
  while true do
    local k = skip_ws(s, i)
    local _, _, e = unit_at(s, k)
    if not e then
      break
    end
    i, n = e, n + 1
  end
  return n > 0 and i or nil
end

-- [0-9]+\(?::[0-9]\{2\}\)\{1,2\} from i: the byte after it and the
-- number of colon groups, or nil.
local function hms_end(s, i)
  local j = skip_digits(s, i)
  if j == i then
    return nil
  end
  local groups = 0
  while groups < 2 and byte(s, j) == 58 and is_digit(byte(s, j + 1)) and is_digit(byte(s, j + 2)) do
    j, groups = j + 3, groups + 1
  end
  if groups == 0 then
    return nil
  end
  return j, groups
end

local function ends_at(s, i)
  return skip_ws(s, i) == #s + 1
end

local function full_p(s)
  local e = units_end(s, 1)
  return e ~= nil and ends_at(s, e)
end

-- org-duration--mixed-re: the units part (group 1) and the H:MM part.
local function mixed(s)
  local e = units_end(s, 1)
  if not e then
    return nil
  end
  local k = skip_ws(s, e)
  local j = hms_end(s, k)
  if j and ends_at(s, j) then
    return s:sub(1, e - 1), s:sub(k, j - 1)
  end
  return nil
end

local function hmm_p(s, two)
  local j, groups = hms_end(s, skip_ws(s, 1))
  return j ~= nil and (not two or groups == 2) and ends_at(s, j)
end

local function bare_p(s)
  local j = skip_digits(s, 1)
  if j == 1 then
    return false
  end
  if byte(s, j) == 46 then
    j = skip_digits(s, j + 1)
  end
  return j == #s + 1
end

-- string-to-number of the strings the regexps admit: blanks, digits, an
-- optional dot and digits.  The value and whether it is an integer.
local function string_to_number(s)
  local n = reader.scan_number(s:sub(skip_ws(s, 1)))
  if not n then
    return 0, true
  end
  if n.float then
    return reader.decimal_float(n.int_part, n.frac, "", false), false
  end
  return tonumber(n.int_part), true
end

local function below(n)
  if not (n < B) then
    fail(OUT_OF_RANGE)
  end
  return n
end

local function to_minutes(d, canonical)
  if d == "" then
    return 0.0
  elseif type(d) == "number" then
    return d
  elseif type(d) ~= "string" then
    error("organ.duration: duration must be a string or a number", 0)
  end
  if hmm_p(d) then
    local parts = {}
    for part in d:gmatch("[^:]+") do
      parts[#parts + 1] = part
    end
    local hours = below((string_to_number(parts[1])))
    local minutes = string_to_number(parts[2])
    local seconds = parts[3] and string_to_number(parts[3]) or 0
    return seconds / 60.0 + minutes + below(60 * hours)
  end
  if full_p(d) then
    local minutes, int = 0, true
    local i = 1
    while true do
      local a = skip_ws(d, i)
      local j, k, e = unit_at(d, a)
      if not j then
        break
      end
      i = e
      local value, vint = string_to_number(d:sub(a, j - 1))
      if vint then
        below(value)
      end
      local mod, mfloat = modifier(d:sub(k, e - 1), canonical)
      local product = value * mod
      local pint = vint and not mfloat
      if pint then
        below(product)
      end
      minutes = minutes + product
      if int and pint then
        below(minutes)
      else
        int = false
      end
    end
    return minutes
  end
  local units_part, hms_part = mixed(d)
  if units_part then
    -- Emacs drops CANONICAL here.
    return to_minutes(units_part) + to_minutes(hms_part)
  end
  if bare_p(d) then
    local value, vint = string_to_number(d)
    if vint then
      below(value)
    end
    return value
  end
  fail("Invalid duration format: " .. string_literal(d))
end

local function trunc(x)
  if x < 0 then
    return math.ceil(x)
  end
  return floor(x)
end

-- Emacs `mod' on floats: fmod, then moved to the divisor's sign.
local function emacs_mod(x, y)
  local r = math.fmod(x, y)
  if (y < 0 and r > 0) or (y >= 0 and r < 0) then
    r = r + y
  end
  return r
end

-- Emacs's (floor x d), the floor of the exact quotient, for 0 <= x < B
-- and integral 0 < d < B: a correctly rounded x / d never rounds up to
-- an integer there.
local function floor_div(x, d)
  return floor(x / d)
end

-- C's %.Nf, as Emacs's format prints a float: LuaJIT's string.format
-- misprints magnitudes below about 1e-152.  0 <= x < 2^47 here.
local function fixed(x, digits)
  local size = digits + 32
  local buf = ffi.new("char[?]", size)
  ffi.C.snprintf(buf, size, "%." .. string.format("%d", digits) .. "f", x)
  return ffi.string(buf)
end

local function is_unit_entry(e)
  return type(e) == "table" and type(e[1]) == "string"
end

local function is_special_entry(e)
  return type(e) == "table" and e[1] == nil and e.special ~= nil
end

local function has_compact(fmt)
  for _, e in ipairs(fmt) do
    if e == "compact" then
      return true
    end
  end
  return false
end

local function check_entry(e)
  if not (e == "compact" or is_unit_entry(e) or is_special_entry(e)) then
    error("organ.duration: format entry is not a unit, special or compact", 0)
  end
end

local from

local function from_mixed(m, fmt, mode, canonical)
  local truncated = {}
  for _, e in ipairs(fmt) do
    if is_unit_entry(e) and modifier(e[1], canonical) > 60 then
      truncated[#truncated + 1] = e
    end
  end
  local min_mod, min_float
  for _, e in ipairs(truncated) do
    local mod, mfloat = modifier(e[1], canonical)
    if not min_mod or mod < min_mod then
      min_mod, min_float = mod, mfloat
    end
  end
  if not min_mod or m < min_mod then
    return from(m, mode, canonical)
  end
  local whole = floor(m)
  local units_part
  if min_float then
    units_part = min_mod * (whole / min_mod)
  else
    units_part = min_mod * floor_div(whole, min_mod)
  end
  local minutes_part = m - units_part
  local compact = has_compact(fmt)
  local head = from(units_part, truncated, canonical)
  return head .. (compact and "" or " ") .. from(minutes_part, mode)
end

local function from_units(m, fmt, digits, canonical)
  local fractional
  if digits then
    if
      not (type(digits) == "number" and digits >= 0 and digits == floor(digits) and digits < B)
    then
      fail("Unknown formatting directive: " .. atom_repr(digits))
    end
    if digits > 2 ^ 30 then
      error("organ.duration: precision above 2^30", 0)
    end
    fractional = digits
  end
  local units = {}
  for _, e in ipairs(fmt) do
    if is_unit_entry(e) then
      units[#units + 1] = e
    end
  end
  -- Emacs's stable sort, largest modifier first, reads the modifiers of
  -- elements 2, 1, 3, 4, ... and of none in a one-element list, so that
  -- order decides which unknown unit signals.
  if #units >= 2 then
    modifier(units[2][1], canonical)
  end
  local selected = {}
  for k, e in ipairs(units) do
    local mod = #units >= 2 and modifier(e[1], canonical) or 0
    local at = k
    while at > 1 and selected[at - 1].mod < mod do
      selected[at] = selected[at - 1]
      at = at - 1
    end
    selected[at] = { unit = e[1], required = e[2] and true or false, mod = mod }
  end
  local separator = has_compact(fmt) and "" or " "
  if fractional then
    local chosen
    for _, u in ipairs(selected) do
      if u.required or modifier(u.unit, canonical) <= m then
        chosen = u
        break
      end
    end
    chosen = chosen or selected[#selected]
    local unit = chosen and chosen.unit
    local mod = modifier(unit, canonical)
    return fixed(m / mod, fractional) .. unit
  end
  local parts = {}
  for _, u in ipairs(selected) do
    local mod = modifier(u.unit, canonical)
    if mod <= m then
      local value = floor_div(m, mod)
      m = m - value * mod
      parts[#parts + 1] = string.format("%s%d%s", separator, value, u.unit)
    elseif u.required then
      parts[#parts + 1] = separator .. "0" .. u.unit
    end
  end
  local text = table.concat(parts):gsub("^[ \t\n\r]+", ""):gsub("[ \t\n\r]+$", "")
  if text:find("[^ \r\t\n]") then
    return text
  end
  return "0" .. (selected[#selected] and selected[#selected].unit or "")
end

from = function(m, fmt, canonical)
  if m < 0 then
    return "-" .. from(math.abs(m), fmt, canonical)
  end
  if fmt == nil or (type(fmt) == "table" and next(fmt) == nil) then
    fmt = DEFAULT_FORMAT
  end
  if fmt == "h:mm" then
    return string.format("%d:%02d", trunc(m / 60), trunc(emacs_mod(m, 60)))
  elseif fmt == "h:mm:ss" then
    local seconds = emacs_mod(60 * m, 60)
    return string.format("%s:%02d", from(floor(m), "h:mm"), trunc(seconds))
  elseif type(fmt) ~= "table" then
    fail("Invalid duration format specification: " .. atom_repr(fmt))
  end
  local special
  for _, e in ipairs(fmt) do
    check_entry(e)
  end
  for _, e in ipairs(fmt) do
    if is_special_entry(e) then
      special = e.special
      break
    end
  end
  if special == "h:mm" or special == "h:mm:ss" then
    return from_mixed(m, fmt, special, canonical)
  end
  return from_units(m, fmt, special or nil, canonical)
end

local function guarded(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then
    return res
  elseif getmetatable(res) == Failure then
    return nil, res.msg
  end
  error(res, 0)
end

--- org-duration-p: whether `s` is a duration string.
function M.p(s)
  return type(s) == "string" and (full_p(s) or mixed(s) ~= nil or hmm_p(s))
end

--- org-duration-to-minutes: the minutes of duration `d` (a string or a
--- number), or nil and the error message.
function M.to_minutes(d, canonical)
  return guarded(to_minutes, d, canonical and true or false)
end

-- TD-94 migration: delete after 2027-02-09
--- The units to_minutes's unit loop reads in string `s`, in order: a list
--- of { first, after }, the unit's first byte and the byte after it.
--- Empty when `s` takes neither the units branch nor the mixed one.
function M.unit_tokens(s)
  local out = {}
  if type(s) ~= "string" or s == "" or hmm_p(s) then
    return out
  end
  local d = full_p(s) and s or mixed(s)
  if not d then
    return out
  end
  local i = 1
  while true do
    local _, k, e = unit_at(d, skip_ws(d, i))
    if not k then
      break
    end
    out[#out + 1] = { k, e }
    i = e
  end
  return out
end

--- org-duration-from-minutes: `minutes` as a duration string in format
--- `fmt`, or nil and the error message.
function M.from_minutes(minutes, fmt, canonical)
  if type(minutes) ~= "number" then
    error("organ.duration: minutes must be a number", 2)
  end
  -- |minutes| * 60 < 2^53, exactly: 2^53 = 60 * Q + 32.
  local a = math.abs(minutes)
  local Q = 150119987579016
  if not (a <= Q or (a < Q + 1 and (a - Q) * 15 < 8)) then
    return nil, OUT_OF_RANGE
  end
  return guarded(from, minutes, fmt, canonical and true or false)
end

--- C's %.Nf of `x` (0 <= x < 2^47), as Emacs's format prints a float.
M.fixed = fixed

--- org-duration-h:mm-only-p: "h:mm:ss" or "h:mm" when no string of
--- `times` uses units, else nil.
function M.h_mm_only_p(times)
  local hms
  for _, t in ipairs(times) do
    if full_p(t) or mixed(t) then
      return nil
    end
    if not hms and hmm_p(t, true) then
      hms = "h:mm:ss"
    end
  end
  return hms or "h:mm"
end

return M
