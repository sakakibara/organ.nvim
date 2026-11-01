-- Time zones for the time builtins (D5a): the rules the C library
-- applies to a TZ setting, from the same zoneinfo files and POSIX TZ
-- strings it reads, so that broken-down times match Emacs's on the
-- same system.  Where glibc and macOS's libc disagree, or the setting
-- is one organ does not reproduce (leap seconds, POSIX strings without
-- rules, TZDIR), the zone refuses `locale'.
--
-- A zone is { kind = "utc" }, { kind = "posix", rule }, or
-- { kind = "tzif", trans, tidx, types, footer, default }.  Seconds since
-- the epoch are int64 cdata, as time_t; a broken-down time is a table
-- with libc's struct tm fields (year counts from 1900, mon from 0) plus
-- `gmtoff` and `zone`.

local R = require("organ.elisp.run")
local ffi = require("ffi")

local M = {}

local I64 = ffi.typeof("int64_t")
M.I64 = I64

local floor = math.floor
local INT_MAX = 2147483647
local INT_MIN = -2147483648
local DAY = 86400

local function refuse(detail)
  R.refuse("locale", detail)
end

--- Floor quotient and remainder of int64 `a` by the positive number `b`.
local function fdivmod(a, b)
  local q = a / b
  local r = a - q * b
  if r < 0 then
    q = q - 1
    r = r + b
  end
  return q, tonumber(r)
end
M.fdivmod = fdivmod

local function is_leap(y)
  return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end
M.is_leap = is_leap

--- Days from 1970-01-01 to the proleptic Gregorian date (y, m, d),
--- m from 1; exact for |y| below 2^40.
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end
M.days_from_civil = days_from_civil

local function civil_from_days(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then
    y = y + 1
  end
  return y, m, d
end

--- __offtime: the broken-down time of `t` seconds at UTC offset `off`,
--- or nil when its year does not fit an int.
local function offtime(t, off)
  local days, rem = fdivmod(t, DAY)
  days = tonumber(days)
  rem = rem + off
  local extra = floor(rem / DAY)
  days = days + extra
  rem = rem - extra * DAY
  local y, m, d = civil_from_days(days)
  local tm_year = y - 1900
  if tm_year > INT_MAX or tm_year < INT_MIN then
    return nil
  end
  return {
    year = tm_year,
    mon = m - 1,
    mday = d,
    hour = floor(rem / 3600),
    min = floor(rem / 60) % 60,
    sec = rem % 60,
    wday = (days + 4) % 7,
    yday = days - days_from_civil(y, 1, 1),
    isdst = 0,
    gmtoff = off,
    zone = "",
  }
end
M.offtime = offtime

-- Times within a few days of the year range an int holds, where the
-- libcs' overflow checks differ.
local YEAR_EDGE = 2147400000

local function near_edge(tm)
  return tm.year + 1900 > YEAR_EDGE or tm.year + 1900 < -YEAR_EDGE
end

-- POSIX TZ strings

-- A zone abbreviation: three or more letters, or <...> holding three or
-- more of [A-Za-z0-9+-].  Both libcs accept these; glibc ignores what
-- macOS rejects, so anything else refuses.
local function parse_name(s, i)
  if s:sub(i, i) == "<" then
    local j = s:find(">", i + 1, true)
    if not j then
      return nil
    end
    local name = s:sub(i + 1, j - 1)
    if #name < 3 or #name > 64 or name:find("[^%w+%-]") then
      return nil
    end
    return name, j + 1
  end
  local j = i
  while s:sub(j, j):match("^%a$") do
    j = j + 1
  end
  if j - i < 3 or j - i > 64 then
    return nil
  end
  return s:sub(i, j - 1), j
end

-- [+-]hh[:mm[:ss]] with hh <= hmax, mm and ss <= 59: seconds and the
-- next index.
local function parse_hms(s, i, signed, hmax)
  local sign = 1
  local c = s:sub(i, i)
  if c == "+" or c == "-" then
    if not signed then
      return nil
    end
    sign = c == "-" and -1 or 1
    i = i + 1
  end
  local h = s:match("^%d+", i)
  if not h or #h > 3 or tonumber(h) > hmax then
    return nil
  end
  local secs = tonumber(h) * 3600
  i = i + #h
  for k = 1, 2 do
    if s:sub(i, i) ~= ":" then
      break
    end
    local part = s:match("^%d+", i + 1)
    if not part or #part > 2 or tonumber(part) > 59 then
      return nil
    end
    secs = secs + tonumber(part) * (k == 1 and 60 or 1)
    i = i + 1 + #part
  end
  return sign * secs, i
end

local function parse_rule(s, i)
  local r
  local c = s:sub(i, i)
  if c == "M" then
    local m, w, d = s:match("^M(%d+)%.(%d+)%.(%d+)", i)
    if not m or #m > 2 or #w > 1 or #d > 1 then
      return nil
    end
    local used = 5 + #m
    m, w, d = tonumber(m), tonumber(w), tonumber(d)
    if m < 1 or m > 12 or w < 1 or w > 5 or d > 6 then
      return nil
    end
    r = { type = "M", m = m, n = w, d = d }
    i = i + used
  elseif c == "J" then
    local n = s:match("^J(%d+)", i)
    if not n or #n > 3 or tonumber(n) < 1 or tonumber(n) > 365 then
      return nil
    end
    r = { type = "J1", d = tonumber(n) }
    i = i + 1 + #n
  else
    local n = s:match("^%d+", i)
    if not n or #n > 3 or tonumber(n) > 365 then
      return nil
    end
    r = { type = "J0", d = tonumber(n) }
    i = i + #n
  end
  r.secs = 7200
  if s:sub(i, i) == "/" then
    local secs, j = parse_hms(s, i + 1, false, 24)
    if not secs then
      return nil
    end
    r.secs, i = secs, j
  end
  return r, i
end

--- The rule of POSIX TZ string `s`, or nil unless both libcs read it
--- alike: { std, std_off, dst, dst_off, start, finish } with offsets
--- east of UTC.
local function parse_posix(s)
  local std, i = parse_name(s, 1)
  if not std then
    return nil
  end
  local off
  off, i = parse_hms(s, i, true, 24)
  if not off then
    return nil
  end
  local rule = { std = std, std_off = -off }
  if i > #s then
    return rule
  end
  local dst
  dst, i = parse_name(s, i)
  if not dst then
    return nil
  end
  rule.dst = dst
  rule.dst_off = rule.std_off + 3600
  local c = s:sub(i, i)
  if c ~= "," and c ~= "" then
    off, i = parse_hms(s, i, true, 24)
    if not off then
      return nil
    end
    rule.dst_off = -off
  end
  -- Without rules each libc falls back on the posixrules file or a
  -- built-in default, which differ by installation.
  if s:sub(i, i) ~= "," then
    return nil
  end
  rule.start, i = parse_rule(s, i + 1)
  if not rule.start or s:sub(i, i) ~= "," then
    return nil
  end
  rule.finish, i = parse_rule(s, i + 1)
  if not rule.finish or i <= #s then
    return nil
  end
  return rule
end
M.parse_posix = parse_posix

local MON_YDAY = {
  [false] = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 },
  [true] = { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 },
}

-- glibc's compute_change: the UTC second when `r` takes effect in
-- `year`, the local time before it being `off` east of UTC.
local function change(r, year, off)
  local leap = is_leap(year)
  local days = days_from_civil(year, 1, 1)
  if r.type == "J1" then
    days = days + r.d - 1
    if r.d >= 60 and leap then
      days = days + 1
    end
  elseif r.type == "J0" then
    days = days + r.d
  else
    local myday = MON_YDAY[leap]
    days = days + myday[r.m]
    local m1 = (r.m + 9) % 12 + 1
    local yy0 = r.m <= 2 and year - 1 or year
    local yy1, yy2 = floor(yy0 / 100), yy0 % 100
    local dow = (floor((26 * m1 - 2) / 10) + 1 + yy2 + floor(yy2 / 4) + floor(yy1 / 4) - 2 * yy1)
      % 7
    local d = r.d - dow
    if d < 0 then
      d = d + 7
    end
    for _ = 2, r.n do
      if d + 7 >= myday[r.m + 1] - myday[r.m] then
        break
      end
      d = d + 7
    end
    days = days + d
  end
  return days * DAY - off + r.secs
end

-- Offset, DST flag and abbreviation `rule` gives at `t` (glibc's
-- __tz_compute, which takes the year from the UTC broken-down time).
-- macOS computes a TZ setting's transitions only through 2569 (a
-- zoneinfo footer's for every year).
local function posix_at(rule, t, last_year)
  if not rule.dst then
    return rule.std_off, 0, rule.std
  end
  local utc = offtime(t, 0)
  if not utc or near_edge(utc) then
    refuse("time zone rule at the edge of the time range")
  end
  local year = utc.year + 1900
  -- glibc computes rules for years before 1970 as if in 1970 and
  -- overflows an int past 5000000; macOS does neither.
  if year < 1970 or year > last_year then
    refuse("time zone rule in " .. year)
  end
  local c0 = change(rule.start, year, rule.std_off)
  local c1 = change(rule.finish, year, rule.dst_off)
  local lo = days_from_civil(year, 1, 1) * DAY + 90000
  local hi = days_from_civil(year + 1, 1, 1) * DAY - 90000
  if c0 < lo or c0 > hi or c1 < lo or c1 > hi then
    refuse("time zone rule change near a new year")
  end
  local tn = tonumber(t)
  -- macOS has no transition before 1970's first, so it starts 1970 in
  -- standard time where glibc's southern rules start it in DST.
  if year == 1970 and c0 > c1 and tn < c1 then
    refuse("time zone rule in 1970")
  end
  local isdst
  if c0 > c1 then
    isdst = tn < c1 or tn >= c0
  else
    isdst = tn >= c0 and tn < c1
  end
  if isdst then
    return rule.dst_off, 1, rule.dst
  end
  return rule.std_off, 0, rule.std
end

-- Zoneinfo files

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function be32s(s, i)
  local v = be32(s, i)
  return v >= 2147483648 and v - 4294967296 or v
end

local function be64(s, i)
  return I64(be32s(s, i)) * 4294967296 + be32(s, i + 4)
end

local function counts(s, i)
  if s:sub(i, i + 3) ~= "TZif" or #s < i + 43 then
    return nil
  end
  return {
    version = s:byte(i + 4),
    isut = be32(s, i + 20),
    isstd = be32(s, i + 24),
    leap = be32(s, i + 28),
    time = be32(s, i + 32),
    type = be32(s, i + 36),
    char = be32(s, i + 40),
  }
end

local function block_size(c, tsize)
  return c.time * tsize + c.time + c.type * 6 + c.char + c.leap * (tsize + 4) + c.isstd + c.isut
end

--- The zone a TZif file's contents give, nil when they are not TZif
--- (the libc then reads the setting as a POSIX string); refuses what
--- organ does not reproduce.
local function parse_tzif(s, what)
  local c = counts(s, 1)
  if not c then
    return nil
  end
  local i, tsize = 45, 4
  if c.version >= 50 then
    i = 45 + block_size(c, 4)
    c = counts(s, i)
    if not c then
      return nil
    end
    i, tsize = i + 44, 8
  end
  if #s < i + block_size(c, tsize) - 1 then
    return nil
  end
  if c.leap > 0 then
    refuse(what .. " has leap seconds")
  end
  if c.type == 0 then
    return nil
  end
  local trans, tidx, types = {}, {}, {}
  for k = 1, c.time do
    trans[k] = tsize == 8 and be64(s, i) or I64(be32s(s, i))
    i = i + tsize
  end
  for k = 1, c.time do
    tidx[k] = s:byte(i) + 1
    if tidx[k] > c.type then
      return nil
    end
    i = i + 1
  end
  local chars_at = i + c.type * 6
  local chars = s:sub(chars_at, chars_at + c.char - 1)
  for k = 1, c.type do
    local idx = s:byte(i + 5)
    local abbr = chars:match("^[^%z]*", idx + 1)
    if idx >= c.char or not abbr then
      return nil
    end
    if abbr:find("[^%w+%-]") then
      refuse(what .. " has abbreviation " .. abbr)
    end
    types[k] = { off = be32s(s, i), isdst = s:byte(i + 4) ~= 0 and 1 or 0, abbr = abbr }
    i = i + 6
  end
  local z = { kind = "tzif", trans = trans, tidx = tidx, types = types }
  -- glibc uses the first standard-time type before the first
  -- transition; macOS uses type 0.
  local default = 1
  while default <= #types and types[default].isdst == 1 do
    default = default + 1
  end
  if default ~= 1 and default <= #types then
    refuse(what .. " starts in daylight saving time")
  end
  z.default = 1
  if tsize == 8 then
    local footer_at = i + c.char + c.leap * 12 + c.isstd + c.isut
    local footer = s:match("^\n([^\n]*)\n", footer_at)
    if not footer then
      refuse(what .. " has no footer")
    end
    if footer ~= "" then
      z.footer = parse_posix(footer)
      if not z.footer then
        refuse(what .. " has footer " .. footer)
      end
    end
  end
  return z
end
M.parse_tzif = parse_tzif

local DEFAULT_DIR = "/usr/share/zoneinfo"

local cache = {}

local function read_file(path)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" then
    return nil
  end
  local key = string.format("%s\0%d\0%d\0%d", path, st.size, st.mtime.sec, st.mtime.nsec)
  local hit = cache[key]
  if hit then
    return hit
  end
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  local z = parse_tzif(s, path) or false
  cache[key] = z
  return z
end

--- The zone a TZ setting names: a zoneinfo file, else a POSIX string.
function M.from_setting(s)
  if s:find("%z") or s:find("[\128-\255]") then
    refuse("TZ " .. s)
  end
  if vim.env.TZDIR then
    refuse("TZDIR")
  end
  local name = s:sub(1, 1) == ":" and s:sub(2) or s
  if name == "" then
    refuse("TZ " .. s)
  end
  local path = name:sub(1, 1) == "/" and name or (DEFAULT_DIR .. "/" .. name)
  local z = read_file(path)
  if z then
    return z
  end
  local rule = s:sub(1, 1) ~= ":" and parse_posix(s)
  if not rule then
    refuse("TZ " .. s)
  end
  return { kind = "posix", rule = rule }
end

M.UTC = { kind = "utc" }

--- The system wall clock zone, as with TZ unset: /etc/localtime.
function M.wall_zone()
  local z = read_file("/etc/localtime")
  if not z then
    refuse("/etc/localtime")
  end
  return z
end

--- Emacs's local zone: the process's TZ setting, else the wall zone.
function M.local_zone()
  local tz = os.getenv("TZ")
  if tz == nil then
    return M.wall_zone()
  end
  return M.from_setting(tz)
end

-- The type index of zone `z` at `t`, or nil when the footer rule
-- applies.
local function tzif_type(z, t)
  local trans = z.trans
  local n = #trans
  if n == 0 or t < trans[1] then
    return z.default
  end
  if t >= trans[n] then
    if z.footer then
      return nil
    end
    return z.tidx[n]
  end
  local lo, hi = 1, n
  while hi - lo > 1 do
    local mid = floor((lo + hi) / 2)
    if trans[mid] <= t then
      lo = mid
    else
      hi = mid
    end
  end
  return z.tidx[lo]
end

--- Offset east of UTC, DST flag and abbreviation of zone `z` at `t`.
function M.at(z, t)
  if z.kind == "utc" then
    return 0, 0, "UTC"
  elseif z.kind == "fixed" then
    return z.off, 0, z.abbr
  elseif z.kind == "posix" then
    return posix_at(z.rule, t, 2569)
  end
  local k = tzif_type(z, t)
  if not k then
    return posix_at(z.footer, t, 5000000)
  end
  local ty = z.types[k]
  return ty.off, ty.isdst, ty.abbr
end

--- localtime_rz: the broken-down time of `t` in zone `z`, or nil when
--- it is out of range (EOVERFLOW).  The abbreviation of the UTC zone,
--- "GMT" on glibc and "UTC" on macOS, is left to the caller.
function M.localtime(z, t)
  if z.kind == "utc" then
    return offtime(t, 0)
  end
  local utc = offtime(t, 0)
  if not utc or near_edge(utc) then
    refuse("time near the end of the time range")
  end
  local off, isdst, abbr = M.at(z, t)
  local tm = offtime(t, off)
  tm.isdst, tm.zone = isdst, abbr
  return tm
end

--- Every UTC offset zone `z` uses.
function M.offsets(z)
  if z.kind == "utc" then
    return { 0 }
  elseif z.kind == "fixed" then
    return { z.off }
  end
  local seen, out = {}, {}
  local function add(o)
    if not seen[o] then
      seen[o] = true
      out[#out + 1] = o
    end
  end
  local rule = z.kind == "posix" and z.rule or z.footer
  if rule then
    add(rule.std_off)
    if rule.dst then
      add(rule.dst_off)
    end
  end
  for _, ty in ipairs(z.types or {}) do
    add(ty.off)
  end
  return out
end

--- A zone of fixed offset `off` and abbreviation `abbr`, as Emacs
--- builds for an integer or (OFFSET ABBR) zone argument.
function M.fixed(off, abbr)
  return { kind = "fixed", off = off, abbr = abbr }
end

return M
