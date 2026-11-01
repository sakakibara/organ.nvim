-- Time (D3, D5a): Emacs 31's time values and the time builtins, ported
-- from timefns.c, gnulib's nstrftime and mktime, and org's
-- org-time-string-to-time and org-time-stamp-format.
--
-- Time values are every form Emacs accepts: nil (now, from ctx.now),
-- integers, floats, (TICKS . HZ) and (HI LO US PS) lists with their
-- shorter forms; arithmetic is exact at every size.  Zones and the
-- C library's broken-down times come from organ.elisp.tz.  What Emacs
-- takes from the C locale or where glibc and macOS differ refuses
-- `locale': day and month names, AM/PM, the locale's date and time
-- formats, the UTC zone's abbreviation ("GMT" on glibc), and
-- non-ASCII format strings.  A local time that falls in a gap or
-- overlap where gnulib's mktime answer depends on earlier calls
-- refuses too.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local bn = require("organ.calc.bn")
local equal = require("organ.elisp.equal")
local ffi = require("ffi")
local format = require("organ.elisp.format")
local list = require("organ.elisp.list")
local num = require("organ.elisp.num")
local str = require("organ.elisp.str")
local tz = require("organ.elisp.tz")

pcall(ffi.cdef, "double ldexp(double, int);")
local C = ffi.C

-- math.frexp is not compiled by LuaJIT; read the exponent bits instead.
local dbits = ffi.new("union { double d; uint32_t w[2]; }")
local HI = ffi.abi("le") and 1 or 0

local M = {}

local NIL, T = V.NIL, V.T
local define = B.define
local wta = B.wta
local floor = math.floor
local I64 = tz.I64

local iadd, isub, imul, idivmod, icmp, isign =
  num.iadd, num.isub, num.imul, num.idivmod, num.icmp, num.sign
local raw, make_int = num.raw, num.make_int

local Q_ERROR = V.intern("error")
local Q_WALL = V.intern("wall")
local Q_NO_BRACKETS = V.intern("no-brackets")
local Q_KEEP_FORMAT = V.intern("keep-format")

local TRILLION = 1e12
local BILLION = 1e9
local MAXI = V.LUA_INT_MAX

local function is_cons(v)
  return type(v) == "table" and v.k == "cons"
end

local function is_str(v)
  return type(v) == "table" and v.k == "str"
end

local function is_sym(v)
  return type(v) == "table" and v.k == "sym"
end

local function arg(argv, i)
  if i <= argv.n then
    return argv[i]
  end
  return NIL
end

local function error_msg(text, ...)
  local items = { V.str(text), ... }
  R.signal(Q_ERROR, V.list(items, select("#", ...) + 1))
end

local function time_overflow()
  error_msg("Specified time is not representable")
end

local function time_spec_invalid()
  error_msg("Invalid time specification")
end

-- Raw integers (organ.elisp.num): Lua numbers within 2^53 - 1, bn beyond.

local function is_zero(x)
  return isign(x) == 0
end

--- Floor quotient and remainder of raw `a` by raw `b`.
local function fdivmod(run, a, b)
  local q, r = idivmod(run, a, b)
  if isign(r) ~= 0 and (isign(r) < 0) ~= (isign(b) < 0) then
    q = isub(run, q, 1)
    r = iadd(run, r, b)
  end
  return q, r
end

local function iabs(x)
  return isign(x) < 0 and num.ineg(x) or x
end

local function igcd(run, a, b)
  a, b = iabs(a), iabs(b)
  while not is_zero(b) do
    run:step(type(b) == "number" and 1 or 4 * #b.d)
    local _, r = idivmod(run, a, b)
    a, b = b, r
  end
  return a
end

local function is_fixnum_int(v)
  return num.is_int(v) and num.emacs_fixnum(raw(v))
end

local INT64_MAX = bn.from_digits_string("9223372036854775807")
local INT64_MIN = bn.neg(bn.from_digits_string("9223372036854775808"))

--- Raw `x` as int64, or nil outside time_t.
local function to_i64(x)
  if type(x) == "number" then
    return I64(x)
  end
  if bn.cmp(x, INT64_MAX) > 0 or bn.cmp(x, INT64_MIN) < 0 then
    return nil
  end
  local neg = x.sign < 0
  local v = I64(0)
  for i = #x.d, 1, -1 do
    v = v * 10000000 + (neg and -x.d[i] or x.d[i])
  end
  return v
end

local function from_i64(v)
  if v <= MAXI and v >= -MAXI then
    return tonumber(v)
  end
  local s = tostring(v):gsub("[LU]+$", "")
  local neg = s:sub(1, 1) == "-"
  local b = bn.from_digits_string(neg and s:sub(2) or s)
  if neg then
    b = bn.neg(b)
  end
  return b
end

--- frexp's exponent of finite nonzero `x`: 2^(e-1) <= |x| < 2^e.
local function exponent(x)
  dbits.d = x
  local biased = math.floor(dbits.w[HI] / 1048576) % 2048
  if biased == 0 then
    local _, e = math.frexp(x)
    return e
  end
  return biased - 1022
end

-- Bit length of non-negative raw `x` (mpz_sizeinbase (x, 2); 1 for 0).
local function bitlen(run, x)
  if type(x) == "number" then
    return x == 0 and 1 or exponent(x)
  end
  local c, n = num.chunks_of(run, x)
  return (n - 1) * 24 + exponent(c[n])
end

local function pow2(run, k)
  if k <= 52 then
    return 2 ^ k
  end
  run:step(1 + floor(k / 64))
  return num.pow2(k)
end

-- frac_to_double: NUMERATOR / DENOMINATOR (positive) rounded to the
-- nearest double, ties to even.
local function frac_to_double(run, n, d)
  local an = iabs(n)
  local ndig, ddig = bitlen(run, an), bitlen(run, d)
  local scale = ddig - ndig + 53
  if scale < 0 then
    d = imul(run, d, pow2(run, -scale))
  else
    scale = math.min(scale, 1074)
    n = imul(run, n, pow2(run, scale))
  end
  local q, r = idivmod(run, n, d)
  local aq = iabs(q)
  local incr
  if bitlen(run, aq) <= 53 then
    local c = icmp(imul(run, iabs(r), 2), d)
    local _, odd = fdivmod(run, aq, 2)
    incr = (c > 0 or (c == 0 and odd == 1)) and 1 or 0
  else
    local _, lo2 = fdivmod(run, aq, 4)
    local lo = lo2 % 2
    incr = (lo == 1 and (floor(lo2 / 2) == 1 or not is_zero(r))) and 2 or 0
  end
  if incr ~= 0 then
    q = isign(n) < 0 and isub(run, q, incr) or iadd(run, q, incr)
  end
  -- mpz_get_d truncates; Q has at most 54 bits.
  local aq2 = iabs(q)
  local _, low = fdivmod(run, aq2, 2)
  if low == 1 and bitlen(run, aq2) > 53 then
    q = isign(q) < 0 and iadd(run, q, 1) or isub(run, q, 1)
  end
  local qd = type(q) == "number" and q or tonumber(bn.to_string(q))
  return C.ldexp(qd, -scale)
end
M.frac_to_double = frac_to_double

-- Decoding time values (decode_lisp_time)

local function now(run)
  local f = run.ctx.now
  local sec, nsec
  if f then
    sec, nsec = f()
  else
    local ts = vim.uv.clock_gettime("realtime")
    sec, nsec = ts.sec, ts.nsec
  end
  return sec, nsec
end

-- Seconds and nanoseconds of TICKS/HZ, floored; sec nil when out of
-- time_t.
local function ticks_to_timespec(run, ticks, hz)
  local q = fdivmod(run, imul(run, ticks, BILLION), hz)
  local sec, ns = fdivmod(run, q, BILLION)
  return to_i64(sec), ns
end

-- 2^scale for a float's ticks, one box per scale as Emacs caches them.
local hz_boxes = {}

local function hz_of_scale(run, scale)
  if scale <= 52 then
    return 2 ^ scale
  end
  local b = hz_boxes[scale]
  if not b then
    b = { k = "big", n = num.pow2(scale) }
    hz_boxes[scale] = b
  end
  run:charge(8 * #b.n.d)
  return b
end

-- (TICKS . HZ) of the finite nonzero double `x`, as values.
local function float_ticks(run, x)
  if x == 0 then
    return 0, 1
  end
  local scale = math.abs(x) < 2.2250738585072014e-308 and 1074 or 53 - exponent(x)
  if scale < 0 then
    scale = 0
  end
  local ticks = num.dbl_to_int(run, C.ldexp(x, scale))
  return ticks, hz_of_scale(run, scale)
end

-- decode_time_components: ticks and hz (values) of the (HI LO US PS)
-- form, or a time_t/ns pair for `secs`.
local function decode_components(run, high, low, usec, psec, hz, cform)
  if not (is_fixnum_int(usec) and is_fixnum_int(psec)) then
    time_spec_invalid()
  end
  if not (num.is_int(high) and num.is_int(low)) then
    time_spec_invalid()
  end
  local us, ps = raw(usec), raw(psec)
  us = iadd(run, us, (fdivmod(run, ps, 1000000)))
  local s_from, us_n = fdivmod(run, us, 1000000)
  local _, ps_n = fdivmod(run, ps, 1000000)
  local s = iadd(run, iadd(run, imul(run, raw(high), 65536), raw(low)), s_from)
  if cform == "timespec" then
    return to_i64(s), us_n * 1000 + floor(ps_n / 1000)
  end
  local ticks
  if hz == TRILLION then
    ticks = iadd(run, imul(run, s, TRILLION), us_n * 1000000 + ps_n)
  elseif hz == 1000000 then
    ticks = iadd(run, imul(run, s, 1000000), us_n)
  else
    ticks = s
  end
  return make_int(run, ticks), hz
end

--- decode_lisp_time of `v` as `cform`: "ticks" gives TICKS and HZ
--- values; "timespec" and "secs" give an int64 second count (nil when
--- out of time_t) and nanoseconds; "double" a number.
local function decode(run, v, cform)
  run:step(1)
  local ticks, hz
  if v == NIL then
    local sec, nsec = now(run)
    if cform == "timespec" or cform == "secs" then
      return I64(sec), nsec
    end
    ticks, hz = make_int(run, iadd(run, imul(run, sec, BILLION), nsec)), BILLION
  elseif is_cons(v) then
    local high, low = v.car, v.cdr
    if is_cons(low) then
      local usec, psec = 0, 0
      local tail = low.cdr
      low = low.car
      hz = 1
      if cform ~= "secs" then
        if is_cons(tail) then
          usec = tail.car
          tail = tail.cdr
          if is_cons(tail) then
            psec = tail.car
            hz = TRILLION
          else
            hz = 1000000
          end
        elseif tail ~= NIL then
          usec = tail
          hz = 1000000
        end
      end
      if cform == "timespec" or cform == "secs" then
        return decode_components(run, high, low, usec, psec, hz, "timespec")
      end
      ticks, hz = decode_components(run, high, low, usec, psec, hz, cform)
    else
      if not (num.is_int(high) and num.is_int(low) and isign(raw(low)) > 0) then
        time_spec_invalid()
      end
      ticks, hz = high, low
    end
  elseif num.is_int(v) then
    ticks, hz = v, 1
  elseif num.is_float(v) then
    local x = v.x
    if x ~= x then
      time_spec_invalid()
    elseif x == math.huge or x == -math.huge then
      time_overflow()
    end
    if cform == "double" then
      return x
    end
    ticks, hz = float_ticks(run, x)
  else
    time_spec_invalid()
  end
  if cform == "double" then
    return frac_to_double(run, raw(ticks), raw(hz))
  elseif cform == "ticks" then
    return ticks, hz
  end
  return ticks_to_timespec(run, raw(ticks), raw(hz))
end
M.decode = decode

--- lisp_time_argument: int64 seconds and nanoseconds of `v`.
local function time_argument(run, v, cform)
  local sec, ns = decode(run, v, cform or "timespec")
  if not sec then
    time_overflow()
  end
  return sec, ns
end

-- Building time values

local function hi_lo(run, t)
  local hi, lo = tz.fdivmod(t, 65536)
  return make_int(run, from_i64(hi)), lo
end

local function new_list(run, items)
  return list.new_list(run, items, #items)
end

-- ticks_hz_list4: (HI LO US PS) of TICKS/HZ, floored to picoseconds.
local function list4(run, ticks, hz)
  local q = fdivmod(run, imul(run, ticks, TRILLION), hz)
  local fullps
  q, fullps = fdivmod(run, q, TRILLION)
  local hi, lo = fdivmod(run, q, 65536)
  return new_list(run, { make_int(run, hi), lo, floor(fullps / 1000000), fullps % 1000000 })
end

local function trillion_factor(hz)
  return type(hz) == "number" and TRILLION % hz == 0
end

local function cons_form(v)
  return is_cons(v) and not is_cons(v.cdr)
end

-- Whether hz values `a` and `b` are one object in Emacs (BASE_EQ).
local function same_hz(a, b)
  if a == b then
    return true
  end
  return type(a) == "number" and type(b) == "number" and a == b
end

-- time_arith: A + B, or A - B when `subtract`.
local function time_arith(run, a, b, subtract)
  local ta_ticks, ta_hz = decode(run, a, "ticks")
  local tb_ticks, tb_hz = decode(run, b, "ticks")
  local ticks, hz
  local hz_v
  if same_hz(ta_hz, tb_hz) then
    hz_v = ta_hz
    hz = raw(ta_hz)
    if tb_ticks == 0 then
      ticks = ta_ticks
    else
      ticks = make_int(run, (subtract and isub or iadd)(run, raw(ta_ticks), raw(tb_ticks)))
    end
  else
    run:step(8)
    local da, db = raw(ta_hz), raw(tb_hz)
    local hzmin = icmp(da, db) < 0 and da or db
    local g = igcd(run, da, db)
    local fa = idivmod(run, da, g)
    local fb = idivmod(run, db, g)
    local ihz = imul(run, fa, db)
    local na, nb = raw(ta_ticks), raw(tb_ticks)
    local iticks = (subtract and isub or iadd)(run, imul(run, fb, na), imul(run, fa, nb))
    local ig = igcd(run, iticks, ihz)
    if icmp(ig, 1) > 0 then
      iticks = idivmod(run, iticks, ig)
      ihz = idivmod(run, ihz, ig)
      if icmp(ihz, hzmin) < 0 then
        local rescale = fdivmod(run, iadd(run, hzmin, isub(run, ihz, 1)), ihz)
        iticks = imul(run, iticks, rescale)
        ihz = imul(run, ihz, rescale)
      end
    end
    hz = ihz
    ticks = make_int(run, iticks)
  end
  if icmp(hz, 1) == 0 then
    return ticks
  end
  if cons_form(a) or cons_form(b) or not trillion_factor(hz) then
    run:charge(32)
    return V.cons(ticks, hz_v or make_int(run, hz))
  end
  return list4(run, raw(ticks), hz)
end

-- Evaluate fn, giving ok and its value, or false when it signals.
local function try_signal(fn)
  local ok, v = pcall(fn)
  if ok then
    return true, v
  end
  if type(v) == "table" and v.elisp == "signal" then
    return false
  end
  error(v, 0)
end

local function cmp_slow(run, a, b)
  local ta_ticks, ta_hz = decode(run, a, "ticks")
  local tb_ticks, tb_hz = decode(run, b, "ticks")
  return icmp(imul(run, raw(ta_ticks), raw(tb_hz)), imul(run, raw(tb_ticks), raw(ta_hz)))
end

local function sgn(x)
  return x < 0 and -1 or (x > 0 and 1 or 0)
end

-- time_cmp, where Emacs answers by object identity before decoding:
-- eq values compare equal, and conses whose cdrs are eq compare their
-- fixnum cars.  Where organ cannot tell whether Emacs's objects are
-- one and the answers differ, it refuses `eq-identity'.
local function time_cmp(run, a, b)
  local same = equal.eq3(run, a, b)
  if same == true then
    return 0
  elseif same == "maybe" then
    local ok, c = try_signal(function()
      return cmp_slow(run, a, b)
    end)
    if ok and c == 0 then
      return 0
    end
    R.refuse("eq-identity", "time comparison")
  end
  if is_cons(a) and is_cons(b) then
    local cdr_eq = equal.eq3(run, a.cdr, b.cdr)
    local x, y = a.car, b.car
    if cdr_eq ~= false and is_fixnum_int(x) and is_fixnum_int(y) then
      local fast = icmp(raw(x), raw(y))
      if cdr_eq == true then
        return fast
      end
      local ok, c = try_signal(function()
        return cmp_slow(run, a, b)
      end)
      if ok and c == fast then
        return fast
      end
      R.refuse("eq-identity", "time comparison")
    end
  elseif is_fixnum_int(a) and is_fixnum_int(b) then
    return icmp(raw(a), raw(b))
  end
  return sgn(cmp_slow(run, a, b))
end

define("current-time", function(run)
  local sec, nsec = now(run)
  local hi, lo = fdivmod(run, sec, 65536)
  return new_list(run, { make_int(run, hi), lo, floor(nsec / 1000), nsec % 1000 * 1000 })
end)

define("float-time", function(run, argv)
  local v = arg(argv, 1)
  if num.is_float(v) then
    return v
  end
  run:charge(16)
  return V.float(decode(run, v, "double"))
end)

define("time-add", function(run, argv)
  return time_arith(run, argv[1], argv[2], false)
end)

define("time-subtract", function(run, argv)
  local a, b = argv[1], argv[2]
  local same = equal.eq3(run, a, b)
  if same == true then
    return new_list(run, { 0, 0, 0, 0 })
  elseif same == "maybe" then
    R.refuse("eq-identity", "time-subtract")
  end
  return time_arith(run, a, b, true)
end)

define("time-less-p", function(run, argv)
  return time_cmp(run, argv[1], argv[2]) < 0 and T or NIL
end)

define("time-equal-p", function(run, argv)
  local a, b = argv[1], argv[2]
  if (a == NIL) ~= (b == NIL) then
    return NIL
  end
  return time_cmp(run, a, b) == 0 and T or NIL
end)

-- Zones (tzlookup)

local function invalid_zone(zone)
  error_msg("Invalid time zone specification", zone)
end

-- The offset of a fixed zone, when the POSIX string Emacs builds for
-- it reads alike in both libcs: glibc caps the hours at 24, macOS at
-- 167.
local function fixed_offset(v)
  local off = raw(v)
  if type(off) ~= "number" or math.abs(off) >= 90000 then
    R.refuse("locale", "zone offset " .. V.int_to_string(v))
  end
  return off
end

--- The zone `zone` (a Lisp zone argument) names.
local function zone_of(run, zone)
  run:step(1)
  if zone == NIL then
    return tz.local_zone()
  elseif zone == T or zone == 0 then
    return tz.UTC
  elseif zone == Q_WALL then
    return tz.wall_zone()
  elseif is_str(zone) then
    return tz.from_setting(zone.s)
  elseif is_fixnum_int(zone) then
    local off = fixed_offset(zone)
    local a = math.abs(off)
    local hour, rem = floor(a / 3600), a % 3600
    local digits, n = 2, hour
    if rem ~= 0 then
      digits, n = 4, n * 100 + floor(rem / 60)
      if rem % 60 ~= 0 then
        digits, n = 6, n * 100 + rem % 60
      end
    end
    local abbr = (off < 0 and "-" or "+") .. string.format("%0" .. digits .. "d", n)
    return tz.fixed(off, abbr)
  elseif is_cons(zone) and is_fixnum_int(zone.car) and is_cons(zone.cdr) then
    local name = zone.cdr.car
    if not is_str(name) then
      local k = type(name) == "table" and name.k
      if name == NIL or k == "cons" or k == "vec" then
        R.refuse("locale", "zone name")
      end
      wta("sequencep", name)
    end
    local off = fixed_offset(zone.car)
    local s = name.s
    if #s < 3 or #s > 64 or s:find("[^%w+%-]") then
      R.refuse("locale", "zone name " .. s)
    end
    return tz.fixed(off, s)
  end
  invalid_zone(zone)
end
M.zone_of = zone_of

-- Broken-down time of int64 `t` in `zone`; signals when out of range.
local function localtime(run, zone, t)
  run:step(4)
  local tm = tz.localtime(zone, t)
  if not tm then
    time_overflow()
  end
  if zone.kind == "utc" then
    tm.zone = nil
  end
  return tm
end

-- mktime (gnulib's __mktime_internal, which glibc shares)

local function isdst_differ(a, b)
  return (a == 0) ~= (b == 0) and a >= 0 and b >= 0
end

-- Seconds of the wall clock time a broken-down time names, counted
-- from 1970-01-01 00:00 as if in UTC (ydhms_diff against the epoch).
local function wall_seconds(year, yday, hour, min, sec)
  local days = tz.days_from_civil(year + 1900, 1, 1) + yday
  return I64(days) * 86400 + hour * 3600 + min * 60 + sec
end

local function tm_wall(tm)
  return wall_seconds(tm.year, tm.yday, tm.hour, tm.min, tm.sec)
end

local MON_YDAY = {
  [false] = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 },
  [true] = { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366 },
}

local function cdiv(a, b)
  local q = a / b
  return q >= 0 and floor(q) or -floor(-q)
end

local function refuse_ambiguous()
  R.refuse("locale", "local time in a daylight saving transition")
end

--- mktime_z of the fields { sec, min, hour, mday, mon, year, isdst }
--- (struct tm's) in `zone`: int64 seconds and the broken-down time,
--- or nil when mktime fails with EOVERFLOW.
local function mktime(run, zone, f)
  local mon_rem = f.mon - cdiv(f.mon, 12) * 12
  local negative = mon_rem < 0 and 1 or 0
  local year = f.year + cdiv(f.mon, 12) - negative
  local yday = MON_YDAY[tz.is_leap(year + 1900)][mon_rem + 12 * negative + 1] - 1 + f.mday
  local sec = math.max(0, math.min(59, f.sec))
  local W = wall_seconds(year, yday, f.hour, f.min, sec)
  local isdst = f.isdst
  local sols = {}
  for _, o in ipairs(tz.offsets(zone)) do
    local t = W - o
    run:step(4)
    local tm = tz.localtime(zone, t)
    if tm and tm.gmtoff == o then
      local dup = false
      for _, s in ipairs(sols) do
        dup = dup or s.t == t
      end
      if not dup then
        sols[#sols + 1] = { t = t, tm = tm }
      end
    end
  end
  local function convert(t)
    run:step(4)
    return tz.localtime(zone, t)
  end
  -- The isdst search of __mktime_internal from solution `s`.
  local function settle(s)
    if not isdst_differ(isdst, s.tm.isdst) then
      return s.t, s.tm
    end
    local stride = 601200
    local bound = 366 * 24 * 60 * 60 + 1 + stride
    for delta = stride, bound - 1, stride do
      for direction = -1, 1, 2 do
        local ot = s.t + delta * direction
        local otm = convert(ot)
        if not otm then
          refuse_ambiguous()
        end
        if not isdst_differ(isdst, otm.isdst) then
          local gt = ot + (W - tm_wall(otm))
          local gtm = convert(gt)
          if gtm then
            return gt, gtm
          end
        end
      end
    end
    -- No time nearby has the requested DST flag: gnulib's mktime then
    -- ignores the flag, glibc's moves the time an hour back.
    if zone.kind ~= "utc" then
      R.refuse("locale", "DST flag the zone does not use nearby")
    end
    return s.t, s.tm
  end
  local t, tm
  if #sols == 1 then
    t, tm = settle(sols[1])
  elseif #sols == 2 and isdst >= 0 then
    local t1, tm1 = settle(sols[1])
    local t2 = settle(sols[2])
    if t1 ~= t2 then
      refuse_ambiguous()
    end
    t, tm = t1, tm1
  elseif #sols == 0 then
    if #tz.offsets(zone) == 1 then
      return nil
    end
    -- A gap: probing settles into alternating between the times W
    -- names under the offsets on each side of it, and stops at the one
    -- whose DST flag it prefers.
    local seq = { W - tz.offsets(zone)[1] }
    for k = 1, 8 do
      local ktm = convert(seq[k])
      if not ktm then
        refuse_ambiguous()
      end
      seq[k + 1] = W - ktm.gmtoff
    end
    local ca, cb = seq[8], seq[9]
    local atm, btm = convert(ca), convert(cb)
    if seq[7] ~= cb or ca == cb or atm.isdst == btm.isdst then
      refuse_ambiguous()
    end
    local want = (isdst < 0 or isdst == 0) and 1 or 0
    if atm.isdst == want then
      t, tm = ca, atm
    else
      t, tm = cb, btm
    end
  else
    refuse_ambiguous()
  end
  if f.sec ~= tm.sec then
    local adj = ((sec == 0 and tm.sec == 60) and 1 or 0) - sec + f.sec
    t = t + adj
    tm = convert(t)
    if not tm then
      return nil
    end
  end
  return t, tm
end
M.mktime = mktime

-- strftime (gnulib's __strftime_internal under the C locale)

local ZERO_PAD, ALWAYS_ZERO_PAD, SIGN_PAD, SPACE_PAD, NO_PAD = 0, 1, 2, 3, 4

local function locale_directive(c)
  R.refuse("locale", "format-time-string %" .. c)
end

local function iso_week_days(yday, wday)
  local big = (floor(366 / 7) + 2) * 7
  return yday - (yday - wday + 4 + big) % 7 + 4 - 1
end

local function c_isleap(y)
  return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end

local function ctrunc(a, b)
  return cdiv(a, b)
end

local function crem(a, b)
  return a - ctrunc(a, b) * b
end

local strftime

-- One NUL-free segment of a format, as __strftime_internal writes it.
local function format_segment(st, f, tm, upcase, yr_spec, width)
  local run = st.run
  local cap = run.caps.string
  local out, len = {}, 0
  local function width_add(w, n, piece, pad)
    local wd = (pad == NO_PAD or w < 0) and 0 or w
    local incr = n < wd and wd or n
    if st.len + len + incr > cap then
      R.limit("string")
    end
    if n < wd then
      out[#out + 1] = string.rep((pad == ALWAYS_ZERO_PAD or pad == SIGN_PAD) and "0" or " ", wd - n)
    end
    out[#out + 1] = piece
    len = len + incr
  end
  local hour12 = tm.hour
  if hour12 > 12 then
    hour12 = hour12 - 12
  elseif hour12 == 0 then
    hour12 = 12
  end
  local fi, flen = 1, #f
  while fi <= flen do
    local pad = ZERO_PAD
    local to_lowcase, to_uppcase = false, upcase
    local change_case = false
    local c = f:sub(fi, fi)
    local function cpy(s)
      if to_lowcase then
        s = s:lower()
      elseif to_uppcase then
        s = s:upper()
      end
      width_add(width, #s, s, pad)
    end
    if c ~= "%" then
      width_add(width, 1, c, pad)
    else
      local percent = fi
      while true do
        fi = fi + 1
        c = f:sub(fi, fi)
        if c == "_" then
          pad = SPACE_PAD
        elseif c == "-" then
          pad = NO_PAD
        elseif c == "+" then
          pad = SIGN_PAD
        elseif c == "0" then
          pad = ALWAYS_ZERO_PAD
        elseif c == "^" then
          to_uppcase = true
        elseif c == "#" then
          change_case = true
        else
          break
        end
      end
      if c:match("^%d$") then
        local digits = f:match("^%d+", fi)
        width = tonumber(digits)
        if #digits > 18 then
          R.refuse("precision", "format-time-string width")
        end
        fi = fi + #digits
        c = f:sub(fi, fi)
      end
      local modifier
      if c == "E" or c == "O" then
        modifier = c
        fi = fi + 1
        c = f:sub(fi, fi)
      end
      local function bad_format()
        cpy(f:sub(percent, fi))
      end
      local digits, negative, always_sign, value, colon_mask
      local number_kind
      local function number(d, v)
        digits, value, negative, number_kind = d, v, v < 0, "number"
      end
      local function signed(d, neg, v)
        digits, negative, value, number_kind = d, neg, v, "signed"
      end
      local function yearish(d, neg, v)
        digits, negative, value, number_kind = d, neg, v, "yearish"
      end
      local function spacepad(d, v)
        digits, value, negative, number_kind = d, v, v < 0, "spacepad"
      end
      local function tz_offset(d, mask, v)
        digits, colon_mask, value, number_kind = d, mask, v, "tz"
      end
      local function subformat(sub, subwidth)
        local s = strftime(st, sub, tm, to_uppcase, pad, subwidth or -1)
        width_add(width, #s, s, pad)
      end
      if c == "%" then
        if fi - 1 ~= percent then
          fi = fi - 1
          bad_format()
        else
          width_add(width, 1, "%", pad)
        end
      elseif c == "a" or c == "A" then
        if modifier then
          bad_format()
        else
          locale_directive(c)
        end
      elseif c == "b" or c == "h" or c == "B" then
        if modifier == "E" then
          bad_format()
        else
          locale_directive(c)
        end
      elseif c == "c" or c == "x" or c == "X" then
        if modifier == "O" then
          bad_format()
        else
          locale_directive(c)
        end
      elseif c == "p" or c == "P" or c == "r" then
        locale_directive(c)
      elseif c == "C" then
        if modifier == "E" then
          locale_directive("EC")
        end
        local negative_year = tm.year < -1900
        local zero_thru_1899 = not negative_year and tm.year < 0
        yearish(2, negative_year, ctrunc(tm.year - (zero_thru_1899 and 99 or 0), 100) + 19)
      elseif c == "D" then
        if modifier then
          bad_format()
        else
          subformat("%m/%d/%y")
        end
      elseif c == "d" then
        if modifier == "E" then
          bad_format()
        else
          number(2, tm.mday)
        end
      elseif c == "e" then
        if modifier == "E" then
          bad_format()
        else
          spacepad(2, tm.mday)
        end
      elseif c == "F" then
        if modifier then
          bad_format()
        else
          local subwidth
          if pad == ZERO_PAD and width < 0 then
            pad = SIGN_PAD
            subwidth = 4
          else
            subwidth = math.max(0, width - 6)
          end
          subformat("%Y-%m-%d", subwidth)
        end
      elseif c == "H" or c == "I" or c == "k" or c == "l" or c == "j" or c == "M" or c == "m" then
        if modifier == "E" then
          bad_format()
        elseif c == "H" then
          number(2, tm.hour)
        elseif c == "I" then
          number(2, hour12)
        elseif c == "k" then
          spacepad(2, tm.hour)
        elseif c == "l" then
          spacepad(2, hour12)
        elseif c == "j" then
          signed(3, tm.yday < -1, tm.yday + 1)
        elseif c == "M" then
          number(2, tm.min)
        else
          signed(2, tm.mon < -1, tm.mon + 1)
        end
      elseif c == "N" then
        if modifier == "E" then
          bad_format()
        else
          local n, ns_digits = st.ns, 9
          if width <= 0 then
            width = ns_digits
          end
          local ndigs = ns_digits
          while width < ndigs or (1 < ndigs and n % 10 == 0) do
            ndigs = ndigs - 1
            n = floor(n / 10)
          end
          if pad == ZERO_PAD then
            pad = ALWAYS_ZERO_PAD
          end
          local s = ndigs > 0 and string.format("%0" .. ndigs .. "d", n) or ""
          width_add(0, #s, s, pad)
          width_add(width - ndigs, 0, "", pad)
        end
      elseif c == "n" then
        width_add(width, 1, "\n", pad)
      elseif c == "q" then
        signed(1, false, floor(tm.mon * 11 / 32) + 1)
      elseif c == "R" then
        subformat("%H:%M")
      elseif c == "S" then
        if modifier == "E" then
          bad_format()
        else
          number(2, tm.sec)
        end
      elseif c == "s" then
        local t = st.seconds(tm)
        if not t then
          time_overflow()
        end
        local s = tostring(t):gsub("[LU]+$", "")
        negative = s:sub(1, 1) == "-"
        digits, always_sign = 1, false
        st.number_text = negative and s:sub(2) or s
        number_kind = "text"
      elseif c == "T" then
        subformat("%H:%M:%S")
      elseif c == "t" then
        width_add(width, 1, "\t", pad)
      elseif c == "u" then
        number(1, (tm.wday - 1 + 7) % 7 + 1)
      elseif c == "U" then
        if modifier == "E" then
          bad_format()
        else
          number(2, floor((tm.yday - tm.wday + 7) / 7))
        end
      elseif c == "V" or c == "g" or c == "G" then
        if modifier == "E" then
          bad_format()
        else
          local year = tm.year + (tm.year < 0 and 300 or -100)
          local year_adjust = 0
          local days = iso_week_days(tm.yday, tm.wday)
          if days < 0 then
            year_adjust = -1
            days = iso_week_days(tm.yday + (365 + (c_isleap(year - 1) and 1 or 0)), tm.wday)
          else
            local d = iso_week_days(tm.yday - (365 + (c_isleap(year) and 1 or 0)), tm.wday)
            if d >= 0 then
              year_adjust = 1
              days = d
            end
          end
          if c == "g" then
            local yy = crem(crem(tm.year, 100) + year_adjust, 100)
            yearish(2, false, yy >= 0 and yy or (tm.year < -1900 - year_adjust and -yy or yy + 100))
          elseif c == "G" then
            yearish(4, tm.year < -1900 - year_adjust, tm.year + 1900 + year_adjust)
          else
            number(2, floor(days / 7) + 1)
          end
        end
      elseif c == "W" then
        if modifier == "E" then
          bad_format()
        else
          number(2, floor((tm.yday - (tm.wday - 1 + 7) % 7 + 7) / 7))
        end
      elseif c == "w" then
        if modifier == "E" then
          bad_format()
        else
          number(1, tm.wday)
        end
      elseif c == "Y" then
        if modifier == "E" then
          locale_directive("EY")
        end
        yearish(4, tm.year < -1900, tm.year + 1900)
      elseif c == "y" then
        if modifier == "E" then
          locale_directive("Ey")
        end
        local yy = crem(tm.year, 100)
        if yy < 0 then
          yy = tm.year < -1900 and -yy or yy + 100
        end
        yearish(2, false, yy)
      elseif c == "Z" then
        if change_case then
          to_uppcase = false
          to_lowcase = true
        end
        if not tm.zone then
          R.refuse("locale", "format-time-string %Z of UTC")
        end
        cpy(tm.zone)
      elseif c == ":" or c == "z" then
        local colons = 0
        if c == ":" then
          colons = 1
          while f:sub(fi + colons, fi + colons) == ":" do
            colons = colons + 1
          end
          if f:sub(fi + colons, fi + colons) ~= "z" then
            bad_format()
            colons = nil
          else
            fi = fi + colons
          end
        end
        if colons then
          local diff = tm.gmtoff
          negative = diff < 0
          if diff == 0 then
            negative = (tm.zone or "U"):sub(1, 1) == "-"
          end
          local hour_diff = ctrunc(diff, 3600)
          local min_diff = crem(ctrunc(diff, 60), 60)
          local sec_diff = crem(diff, 60)
          if colons == 3 then
            if sec_diff ~= 0 then
              colons = 2
            elseif min_diff ~= 0 then
              colons = 1
            end
          end
          if colons == 0 then
            tz_offset(5, 0, hour_diff * 100 + min_diff)
          elseif colons == 1 then
            tz_offset(6, 4, hour_diff * 100 + min_diff)
          elseif colons == 2 then
            tz_offset(9, 20, hour_diff * 10000 + min_diff * 100 + sec_diff)
          elseif colons == 3 then
            tz_offset(3, 0, hour_diff)
          else
            bad_format()
          end
        end
      elseif c == "" then
        fi = fi - 1
        bad_format()
      else
        bad_format()
      end
      if number_kind then
        local mask = 0
        if number_kind == "tz" then
          always_sign = true
          mask = colon_mask
        elseif number_kind == "yearish" then
          if pad == ZERO_PAD then
            pad = yr_spec
          end
          local u = negative and value % 4294967296 or value
          always_sign = pad == SIGN_PAD and ((digits == 2 and 99 or 9999) < u or digits < width)
        elseif number_kind == "spacepad" then
          if pad == ZERO_PAD then
            pad = SPACE_PAD
          end
          always_sign = false
        elseif number_kind ~= "text" then
          always_sign = false
        end
        local text
        if number_kind == "text" then
          text = st.number_text
        else
          local u = math.abs(value)
          local chars = {}
          repeat
            if mask % 2 == 1 then
              chars[#chars + 1] = ":"
            end
            mask = floor(mask / 2)
            chars[#chars + 1] = tostring(u % 10)
            u = floor(u / 10)
          until u == 0 and mask == 0
          text = string.reverse(table.concat(chars))
        end
        if pad == ZERO_PAD then
          pad = ALWAYS_ZERO_PAD
        end
        if width < 0 then
          width = digits
        end
        local sign_char = negative and "-" or (always_sign and "+" or nil)
        if sign_char then
          local shortage = width - 1 - #text
          if pad == SPACE_PAD then
            if shortage < 0 then
              -- gnulib's unsigned padding count wraps and Emacs aborts.
              R.refuse("precision", "format-time-string width")
            end
            width_add(0, shortage, string.rep(" ", shortage), pad)
            width = width - shortage
          end
          width_add(0, 1, sign_char, pad)
          width = width - 1
        end
        cpy(text)
      end
    end
    width = -1
    fi = fi + 1
  end
  local s = table.concat(out)
  run:step(1 + floor(#s / 64))
  return s
end

--- The C library strftime of format `f` (NUL-free) for `tm`.
strftime = function(st, f, tm, upcase, yr_spec, width)
  return format_segment(st, f, tm, upcase, yr_spec, width)
end

local function format_time(run, fmt, tm, ns, zone)
  local st = { run = run, ns = ns, len = 0 }
  st.seconds = function(t)
    local secs = mktime(run, zone, {
      sec = t.sec,
      min = t.min,
      hour = t.hour,
      mday = t.mday,
      mon = t.mon,
      year = t.year,
      isdst = t.isdst,
    })
    return secs
  end
  local parts = {}
  local start = 1
  while true do
    local z = fmt:find("%z", start)
    local seg = fmt:sub(start, z and z - 1 or #fmt)
    local s = strftime(st, seg, tm, false, ZERO_PAD, -1)
    st.len = st.len + #s + (z and 1 or 0)
    parts[#parts + 1] = s
    if not z then
      break
    end
    start = z + 1
  end
  return table.concat(parts, "\0")
end

define("format-time-string", function(run, argv)
  local fmt = argv[1]
  local sec, ns = time_argument(run, arg(argv, 2))
  if not is_str(fmt) then
    wta("stringp", fmt)
  end
  local zone = zone_of(run, arg(argv, 3))
  if fmt.s:find("[\128-\255]") then
    R.refuse("locale", "format-time-string of non-ASCII text")
  end
  local tm = localtime(run, zone, sec)
  return str.new_string(run, format_time(run, fmt.s, tm, ns, zone))
end)

define("decode-time", function(run, argv)
  local form = arg(argv, 3)
  local t, hz, hz_v, th_ticks
  if form == T then
    local ticks
    ticks, hz_v = decode(run, arg(argv, 1), "ticks")
    th_ticks = raw(ticks)
    hz = raw(hz_v)
    t = ticks_to_timespec(run, th_ticks, hz)
    if not t then
      time_overflow()
    end
  else
    t = time_argument(run, arg(argv, 1), "secs")
    hz = 1
  end
  local zone = zone_of(run, arg(argv, 2))
  local tm = localtime(run, zone, t)
  local sec
  if icmp(hz, 1) == 0 then
    sec = tm.sec
  else
    local _, r = fdivmod(run, th_ticks, hz)
    run:charge(32)
    sec = V.cons(make_int(run, iadd(run, imul(run, hz, tm.sec), r)), hz_v)
  end
  return new_list(run, {
    sec,
    tm.min,
    tm.hour,
    tm.mday,
    tm.mon + 1,
    tm.year + 1900,
    tm.wday,
    tm.isdst < 0 and -1 or (tm.isdst == 0 and NIL or T),
    tm.gmtoff,
  })
end)

-- check_tm_member: OBJ - OFFSET as an int.
local function tm_member(obj, offset)
  if not is_fixnum_int(obj) then
    wta("fixnump", obj)
  end
  local n = raw(obj)
  if type(n) ~= "number" or n - offset > 2147483647 or n - offset < -2147483648 then
    time_overflow()
  end
  return n - offset
end

local function encode(run, secarg, minarg, hourarg, mdayarg, monarg, yeararg, zone, isdst)
  local ticks, hz_v = decode(run, secarg, "ticks")
  local sec, subsec
  local hz = raw(hz_v)
  if icmp(hz, 1) == 0 then
    sec, subsec = ticks, 0
  else
    local s, r = fdivmod(run, raw(ticks), hz)
    sec, subsec = make_int(run, s), r
  end
  local f = {
    sec = tm_member(sec, 0),
    min = tm_member(minarg, 0),
    hour = tm_member(hourarg, 0),
    mday = tm_member(mdayarg, 0),
    mon = tm_member(monarg, 1),
    year = tm_member(yeararg, 1900),
    isdst = isdst,
  }
  local z = zone_of(run, zone)
  local t = mktime(run, z, f)
  if not t then
    time_overflow()
  end
  if icmp(hz, 1) == 0 then
    local hi, lo = hi_lo(run, t)
    return new_list(run, { hi, lo })
  end
  run:charge(32)
  local v = iadd(run, imul(run, from_i64(t), hz), subsec)
  return V.cons(make_int(run, v), hz_v)
end

local function encode_list(run, a)
  local fields = {}
  local tail = a
  for i = 1, 6 do
    if not is_cons(tail) then
      wta("consp", tail)
    end
    fields[i] = tail.car
    tail = tail.cdr
  end
  local zone, isdst = NIL, -1
  if tail ~= NIL then
    if not is_cons(tail) then
      wta("consp", tail)
    end
    tail = tail.cdr
    if not is_cons(tail) then
      wta("consp", tail)
    end
    local dstflag = tail.car
    tail = tail.cdr
    if not is_cons(tail) then
      wta("consp", tail)
    end
    zone = tail.car
    if is_sym(dstflag) and not is_fixnum_int(zone) and not is_cons(zone) then
      isdst = dstflag ~= NIL and 1 or 0
    end
  end
  return encode(run, fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], zone, isdst)
end

define("encode-time", function(run, argv)
  if argv.n == 1 then
    return encode_list(run, argv[1])
  end
  local zone = argv.n > 6 and argv[argv.n] or NIL
  return encode(run, argv[1], argv[2], argv[3], argv[4], argv[5], argv[6], zone, -1)
end)

-- org.el

-- org-ts-regexp0 matched against `s` from its first match: the year,
-- month, day, hour and minute digit strings (hour and minute nil when
-- absent).
local function match_ts(run, s)
  local n = #s
  run:step(1 + floor(n / 16))
  for i = 1, n - 9 do
    local y, mo, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)", i)
    if y then
      local j = i + 10
      local k = j
      while s:sub(k, k) == " " do
        k = k + 1
      end
      if k > j then
        local m = k
        while m <= n and not s:sub(m, m):find("[%]+0-9>\r\n %-]") do
          m = m + 1
        end
        if m > k then
          j = m
        end
      end
      k = j
      while s:sub(k, k) == " " do
        k = k + 1
      end
      if k > j then
        local h, mm = s:match("^(%d%d?):(%d%d)", k)
        if h then
          return y, mo, d, h, mm
        end
      end
      return y, mo, d
    end
  end
end

define("org-time-string-to-time", function(run, argv)
  local s = argv[1]
  if not is_str(s) then
    wta("stringp", s)
  end
  local y, mo, d, h, mm = match_ts(run, s.s)
  if not y then
    local text = format.format(run, { n = 2, V.str("Not an Org time string: %s"), s }, true)
    R.signal(Q_ERROR, V.list({ text }))
  end
  return encode(
    run,
    0,
    tonumber(mm or "0"),
    tonumber(h or "0"),
    tonumber(d),
    tonumber(mo),
    tonumber(y),
    NIL,
    -1
  )
end)

local TIMESTAMP_FORMATS = { V.str("%Y-%m-%d %a"), V.str("%Y-%m-%d %a %H:%M") }

define("org-time-stamp-format", function(run, argv)
  local with_time, inactive, custom = arg(argv, 1), arg(argv, 2), arg(argv, 3)
  if custom ~= NIL then
    R.refuse("free-variable", "org-timestamp-custom-formats")
  end
  local fmt = TIMESTAMP_FORMATS[with_time ~= NIL and 2 or 1]
  if inactive ~= Q_KEEP_FORMAT then
    local s = fmt.s
    local first, last = s:sub(1, 1), s:sub(-1)
    if (first == "<" and last == ">") or (first == "[" and last == "]") then
      fmt = str.new_string(run, s:sub(2, -2))
    end
  end
  if inactive == Q_NO_BRACKETS or inactive == Q_KEEP_FORMAT then
    return fmt
  elseif inactive == NIL then
    return str.new_string(run, "<" .. fmt.s .. ">")
  end
  return str.new_string(run, "[" .. fmt.s .. "]")
end)

return M
