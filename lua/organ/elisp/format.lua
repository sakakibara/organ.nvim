-- `format' and `format-message' (D5c): a port of editfns.c's
-- styled_format, with the C library's conversions it relies on done
-- in Lua: integers in every base and floats through their exact
-- decimal expansion, rounded half to even as glibc and macOS do.
--
-- Where the platforms differ organ refuses: precision above 99 and
-- negative %b with a precision (`precision'), integers %e %f %g would
-- format as a long double (`precision'), a NaN printed with a sign or
-- whose sign the platform decides (`nan'); format-message quotes follow
-- text-quoting-style (`locale').

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local bn = require("organ.calc.bn")
local chars = require("organ.elisp.chars")
local num = require("organ.elisp.num")
local printer = require("organ.elisp.printer")
local str = require("organ.elisp.str")

local M = {}

local Q_ERROR = V.intern("error")

local byte, sub, rep = string.byte, string.sub, string.rep
local floor = math.floor

local HUGE = math.huge
local PTRDIFF_MAX = 2 ^ 63
local MAX_BUFSIZE = 2 ^ 61
local MAX_PRECISION = 99
local TWO64 = 2 ^ 64
local BN_INTMAX_MIN = num.dbl_to_raw(-(2 ^ 63))
local BN_UINTMAX_END = num.dbl_to_raw(TWO64)

local function is_str(v)
  return type(v) == "table" and v.k == "str"
end

local function is_sym(v)
  return type(v) == "table" and v.k == "sym"
end

local function fail(msg)
  R.signal(Q_ERROR, V.list({ V.str(msg) }))
end

-- Exact decimals

local function bn_pow(base, k)
  local result, b = bn.one(), bn.from_int(base)
  while k > 0 do
    if k % 2 == 1 then
      result = bn.mul(result, b)
    end
    k = floor(k / 2)
    if k > 0 then
      b = bn.mul(b, b)
    end
  end
  return result
end

--- The exact decimal of finite x >= 0: digits `d` (no leading zeros,
--- "" for zero) and scale `k`, x = d / 10^k.
local function exact_decimal(run, x)
  if x == 0 then
    return "", 0
  end
  local m, e = math.frexp(x)
  local mant, e2 = m * 2 ^ 53, e - 53
  while e2 < 0 and mant % 2 == 0 do
    mant, e2 = mant / 2, e2 + 1
  end
  local n
  if e2 >= 0 then
    n = bn.mul(bn.from_int(mant), bn_pow(2, e2))
  else
    n = bn.mul(bn.from_int(mant), bn_pow(5, -e2))
  end
  local d = bn.to_string(n)
  run:step(1 + floor(#d * #d / 4096))
  return d, e2 >= 0 and 0 or -e2
end

local function increment(d)
  local i = #d
  while i >= 1 and byte(d, i) == 57 do
    i = i - 1
  end
  if i == 0 then
    return "1" .. rep("0", #d)
  end
  return sub(d, 1, i - 1) .. string.char(byte(d, i) + 1) .. rep("0", #d - i)
end

--- d / 10^k rounded half to even to `p` fractional digits (p may be
--- negative): the digits of the result times 10^p, "" for zero.
local function round_to(d, k, p)
  if p >= k then
    if d == "" then
      return ""
    end
    return d .. rep("0", p - k)
  end
  local cut = #d - (k - p)
  if cut < 0 then
    return ""
  end
  local kept, rest = sub(d, 1, cut), sub(d, cut + 1)
  local r = byte(rest, 1) or 48
  local up = r > 53
  if r == 53 then
    up = rest:find("[1-9]", 2) ~= nil or (kept ~= "" and byte(kept, #kept) % 2 == 1)
  end
  if up then
    kept = increment(kept)
  end
  return (kept:gsub("^0+", ""))
end

local function fixed(d, k, p, sharp)
  local digits = round_to(d, k, p)
  if #digits <= p then
    digits = rep("0", p + 1 - #digits) .. digits
  end
  local int, frac = sub(digits, 1, #digits - p), sub(digits, #digits - p + 1)
  if p == 0 then
    return sharp and int .. "." or int
  end
  return int .. "." .. frac
end

-- Scientific digits: `p` + 1 significant digits and the exponent.
local function sci_digits(d, k, p)
  if d == "" then
    return rep("0", p + 1), 0
  end
  local x = #d - 1 - k
  local digits = round_to(d, k, p - x)
  if #digits > p + 1 then
    digits = sub(digits, 1, p + 1)
    x = x + 1
  end
  return digits, x
end

local function sci(digits, x, sharp)
  local mant = sub(digits, 1, 1)
  if #digits > 1 then
    mant = mant .. "." .. sub(digits, 2)
  elseif sharp then
    mant = mant .. "."
  end
  local ex = math.abs(x)
  return mant .. "e" .. (x < 0 and "-" or "+") .. (ex < 10 and "0" or "") .. ex
end

--- C's %e, %f or %g of double `x` with precision `prec` (-1 when not
--- given) and flags, as sprintf prints it; `nan_neg` is a NaN's sign.
local function c_float(run, conv, x, prec, plus, space, sharp, nan_neg)
  if x ~= x then
    if nan_neg == nil then
      R.refuse("nan", "NaN of unknown sign", { x })
    elseif nan_neg or plus or space then
      R.refuse("nan", "NaN with a sign", { x })
    end
    return "nan"
  end
  local sign = ""
  if num.signbit(x) then
    sign = "-"
  elseif plus then
    sign = "+"
  elseif space then
    sign = " "
  end
  if x == HUGE or x == -HUGE then
    return sign .. "inf"
  end
  local d, k = exact_decimal(run, math.abs(x))
  if conv == "f" then
    return sign .. fixed(d, k, prec < 0 and 6 or prec, sharp)
  elseif conv == "e" then
    local p = prec < 0 and 6 or prec
    local digits, ex = sci_digits(d, k, p)
    return sign .. sci(digits, ex, sharp)
  end
  local p = prec < 0 and 6 or (prec == 0 and 1 or prec)
  local digits, ex = sci_digits(d, k, p - 1)
  local out
  if p > ex and ex >= -4 then
    out = fixed(d, k, p - 1 - ex, sharp)
  else
    out = sci(digits, ex, sharp)
  end
  if not sharp then
    local mant, tail = out:match("^([^e]*)(.*)$")
    if mant:find(".", 1, true) then
      mant = mant:gsub("0+$", ""):gsub("%.$", "")
    end
    out = mant .. tail
  end
  return sign .. out
end

-- Integers

local DIGITS = "0123456789abcdef"

--- Magnitude digits of non-negative raw integer `m` in base 8, 16 or 2.
local function base_digits(run, m, base)
  if m == 0 then
    return "0"
  end
  local c, n = num.chunks_of(run, m)
  local per = base == 8 and 8 or base == 16 and 6 or 24
  local parts = {}
  for i = 1, n do
    local v, ds = c[i], {}
    for j = per, 1, -1 do
      local r = v % base
      ds[j] = sub(DIGITS, r + 1, r + 1)
      v = (v - r) / base
    end
    parts[n - i + 1] = table.concat(ds)
  end
  run:step(1 + floor(n / 8))
  return (table.concat(parts):gsub("^0+", ""))
end

local function magnitude(x)
  if type(x) == "number" then
    return x < 0, x < 0 and -x or x
  end
  if x.sign < 0 then
    return true, bn.neg(x)
  end
  return false, x
end

local function decimal_digits(m)
  if type(m) == "number" then
    return string.format("%d", m)
  end
  return bn.to_string(m)
end

--- C's integer conversion of a magnitude's `digits` with precision
--- `prec` (-1 when not given) and the # flag.
local function c_digits(conv, digits, prec, sharp)
  if prec >= 0 then
    if digits == "0" and prec == 0 then
      digits = ""
    end
    if #digits < prec then
      digits = rep("0", prec - #digits) .. digits
    end
  end
  if sharp then
    if conv == "o" and byte(digits, 1) ~= 48 then
      digits = "0" .. digits
    elseif (conv == "x" or conv == "X") and digits:find("[1-9a-fA-F]") then
      digits = "0" .. conv .. digits
    end
  end
  return digits
end

local function is_digit(c)
  return c ~= nil and c >= 48 and c <= 57
end

local function is_hexdigit(c)
  return c ~= nil and ((c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70))
end

--- The padding and zero insertion after the conversion (styled_format's
--- common tail): `p` is the converted text, `prefix` what goes after
--- its sign, `excess` the zeros precision adds.
local function assemble(run, p, prefix, conv, float_conv, excess, width, minus, zero, sharp)
  local numwidth = #prefix + #p + excess
  local padding = numwidth < width and width - numwidth or 0
  run:check_string(numwidth + padding)
  local leading_zeros = excess
  local b0 = byte(p, 1)
  local signedp = (b0 == 45 or b0 == 43 or b0 == 32) and 1 or 0
  local beglen = signedp
  if not float_conv and byte(p, signedp + 1) == 48 and byte(p, signedp + 2) == byte(conv) then
    beglen = beglen + 2
  end
  if zero and is_hexdigit(byte(p, beglen + 1)) then
    leading_zeros = leading_zeros + padding
    padding = 0
  end
  if leading_zeros == 0 and sharp and conv == "o" and byte(p, beglen + 1) ~= 48 then
    leading_zeros = 1
    if padding ~= 0 then
      padding = padding - 1
    end
  end
  local lead = minus and 0 or padding
  return rep(" ", lead)
    .. sub(p, 1, beglen)
    .. prefix
    .. rep("0", leading_zeros)
    .. sub(p, beglen + 1)
    .. rep(" ", padding - lead)
end

-- The format string

local function str2num(s, i)
  local n = 0
  while true do
    local c = byte(s, i)
    if not c or c < 48 or c > 57 then
      break
    end
    n = n * 10 + (c - 48)
    if n >= PTRDIFF_MAX then
      n = PTRDIFF_MAX
    end
    i = i + 1
  end
  return n, i
end

local CONVERSIONS = {}
for c in ("cdfegioxXbB"):gmatch(".") do
  CONVERSIONS[c] = true
end

local function is_fixnum(v)
  return type(v) == "number" or (type(v) == "table" and v.k == "big" and num.emacs_fixnum(v.n))
end

--- The text of a %s conversion of string value `s`: its characters
--- within precision `prec` (-1: all) and its display width, which is
--- measured only when `measure`.
local function string_conv(run, s, prec, measure)
  if prec == 0 then
    return "", 0
  end
  if not measure then
    return s.s, 0
  end
  if s.props then
    R.refuse("width", "text properties", { s })
  end
  local text, width, i = s.s, 0, 1
  while i <= #text do
    run:step(1)
    local c, j = V.utf8_next(text, i)
    local w = chars.fixed_width(c)
    if not w then
      R.refuse("width", string.format("U+%04X", c), { c })
    end
    if prec > 0 and prec - width < w then
      return sub(text, 1, i - 1), width
    end
    width = width + w
    i = j
  end
  run:step(1)
  return text, width
end

--- styled_format of argv[1] (the format string) and its arguments;
--- `message`: format-message.
function M.format(run, argv, message)
  local fmt = argv[1]
  if not is_str(fmt) then
    B.wta("stringp", fmt)
  end
  local s = fmt.s
  if message and s:find("[`']") then
    R.refuse("locale", "format-message")
  end
  local nargs = argv.n
  local out, total = {}, 0
  local props = fmt.props == true
  local new_result = false
  local function emit(piece)
    total = total + #piece
    run:check_string(total)
    out[#out + 1] = piece
  end
  local n = 0
  local i = 1
  local len = #s
  while i <= len do
    local c = byte(s, i)
    if c ~= 37 then
      local j = i + 1
      while j <= len and byte(s, j) ~= 37 do
        j = j + 1
      end
      emit(sub(s, i, j - 1))
      i = j
    else
      local f = i + 1
      if is_digit(byte(s, f)) then
        local num_, e = str2num(s, f)
        if byte(s, e) == 36 then
          n = num_ - 1
          f = e + 1
        end
      end
      local minus, plus, space, sharp, zero = false, false, false, false, false
      while true do
        local fc = byte(s, f)
        if fc == 45 then
          minus = true
        elseif fc == 43 then
          plus = true
        elseif fc == 32 then
          space = true
        elseif fc == 35 then
          sharp = true
        elseif fc == 48 then
          zero = true
        else
          break
        end
        f = f + 1
      end
      space = space and not plus
      zero = zero and not minus
      local width
      width, f = str2num(s, f)
      if width >= MAX_BUFSIZE then
        fail("Maximum string size exceeded")
      end
      local precision_given = byte(s, f) == 46
      local precision = HUGE
      if precision_given then
        precision, f = str2num(s, f + 1)
      end
      if f > len then
        fail("Format string ends in middle of format specifier")
      end
      local cb = byte(s, f)
      local conv = string.char(cb)
      local spec_end = f + 1
      if cb >= 128 then
        local _, nx = V.utf8_next(s, f)
        conv = sub(s, f, nx - 1)
        spec_end = nx
      end
      if conv == "%" then
        new_result = true
        emit("%")
      else
        n = n + 1
        if not (n < nargs) then
          fail("Not enough arguments for format string")
        end
        local a = argv[n + 1]
        if conv == "S" or (conv == "s" and not is_str(a) and not is_sym(a)) then
          a = str.new_string(
            run,
            conv == "S" and printer.prin1(run, a, false) or printer.princ(run, a)
          )
          conv = "s"
        elseif conv == "c" then
          if is_fixnum(a) and not (type(a) == "number" and a >= 0 and a < 128) then
            a = B.defs["char-to-string"].fn(run, { n = 1, a })
            conv = "s"
          end
          zero = false
        end
        if is_sym(a) then
          a = a.name
        end
        local float_conv = conv == "e" or conv == "f" or conv == "g"
        if conv == "s" then
          if spec_end > len and i == 1 and spec_end == 3 and not fmt.props then
            return a
          end
          if precision_given and precision > MAX_PRECISION then
            R.refuse("precision", tostring(precision))
          end
          local text, w =
            string_conv(run, a, precision_given and precision or -1, width > 0 or precision_given)
          local padding = w < width and width - w or 0
          run:check_string(total + #text + padding)
          if minus then
            emit(text .. rep(" ", padding))
          else
            emit(rep(" ", padding) .. text)
          end
          props = props or a.props == true
          new_result = true
        elseif not CONVERSIONS[conv] then
          fail("Invalid format operation %" .. conv)
        elseif not (is_fixnum(a) or (conv ~= "c" and (num.is_int(a) or num.is_float(a)))) then
          R.refuse("locale", "Format specifier doesn't match argument type")
        else
          if precision_given and precision > MAX_PRECISION then
            R.refuse("precision", tostring(precision))
          end
          emit(M.number(run, conv, a, {
            precision_given = precision_given,
            precision = precision,
            width = width,
            minus = minus,
            plus = plus,
            space = space,
            sharp = sharp,
            zero = zero,
            float_conv = float_conv,
          }))
          new_result = true
        end
      end
      i = spec_end
    end
  end
  if not new_result then
    return fmt
  end
  run:step(1 + floor(total / 64))
  return str.new_string(run, table.concat(out), props)
end

--- The text of numeric conversion `conv` of number value `a` under
--- spec `o` (styled_format's number branch).
function M.number(run, conv, a, o)
  local prec = o.precision_given and o.precision or -1
  local sharp = o.sharp
  if conv == "d" or conv == "i" then
    sharp = false
  end
  local zero = o.zero
  if not (o.float_conv or conv == "c") then
    zero = zero and not o.precision_given
  end
  local p
  local prefix, excess = "", 0
  if o.float_conv then
    local x, nan_neg
    if num.is_float(a) then
      x, nan_neg = a.x, a.nan_neg
    else
      x = num.float_of(run, a)
      if
        type(a) ~= "number"
        and bn.cmp(a.n, BN_INTMAX_MIN) >= 0
        and bn.cmp(a.n, BN_UINTMAX_END) < 0
        and num.num_cmp(a, V.float(x)) ~= 0
      then
        R.refuse("precision", "long double")
      end
    end
    p = c_float(run, conv, x, prec, o.plus, o.space, sharp, nan_neg)
  elseif conv == "c" then
    if prec == 0 then
      if o.width > 0 and (a == 45 or a == 43 or a == 32) then
        R.refuse("precision", "%.0c of a sign character")
      end
      p = ""
    else
      p = string.char(a)
    end
  else
    local big
    if num.is_float(a) then
      if conv ~= "d" and conv ~= "i" and not (math.abs(a.x) < TWO64) then
        big = num.dbl_to_int(run, a.x)
      end
    elseif not is_fixnum(a) then
      big = a
    end
    if big then
      local neg, m = magnitude(type(big) == "number" and big or big.n)
      local base = (conv == "d" or conv == "i") and 10
        or conv == "o" and 8
        or (conv == "x" or conv == "X") and 16
        or 2
      local digits = base == 10 and decimal_digits(m) or base_digits(run, m, base)
      if conv == "X" then
        digits = digits:upper()
      end
      p = (neg and "-" or "") .. digits
      local cut = math.min(o.precision, #p)
      excess = o.precision_given and o.precision - cut or 0
      if (o.plus or o.space) and not neg then
        prefix = o.plus and "+" or " "
      end
      if sharp and not (conv == "d" or conv == "i" or conv == "o") then
        prefix = prefix .. "0" .. conv
      end
    elseif conv == "d" or conv == "i" then
      if num.is_float(a) then
        local x = a.x
        if x == x then
          x = x >= 0 and math.floor(x) or math.ceil(x)
          if x == 0 then
            x = 0
          end
        end
        p = c_float(run, "f", x, 0, o.plus, o.space, false, a.nan_neg)
        local signedp = (byte(p, 1) < 48 or byte(p, 1) > 57) and 1 or 0
        local cut = math.min(o.precision, #p - signedp)
        excess = o.precision_given and o.precision - cut or 0
      else
        local neg, m = magnitude(type(a) == "number" and a or a.n)
        local sign = neg and "-" or o.plus and "+" or o.space and " " or ""
        p = sign .. c_digits("d", decimal_digits(m), prec, false)
      end
    else
      local neg, m
      if num.is_float(a) then
        local ad = math.abs(a.x)
        neg = a.x <= -1
        m = num.dbl_to_raw(math.floor(ad))
      else
        neg, m = magnitude(type(a) == "number" and a or a.n)
      end
      if conv == "b" or conv == "B" then
        if neg and o.precision_given then
          R.refuse("precision", "negative %b")
        end
        local bits = m == 0 and (prec < 0 and "0" or "") or base_digits(run, m, 2)
        p = (neg and "-" or "") .. bits
        local cut = math.min(o.precision, #p)
        excess = o.precision_given and o.precision - cut or 0
        if (o.plus or o.space) and not neg then
          prefix = o.plus and "+" or " "
        end
        if sharp and m ~= 0 then
          prefix = prefix .. "0" .. conv
        end
      else
        local digits = base_digits(run, m, conv == "o" and 8 or 16)
        if conv == "X" then
          digits = digits:upper()
        end
        local sign = neg and "-" or o.plus and "+" or o.space and " " or ""
        p = sign .. c_digits(conv, digits, prec, sharp)
      end
    end
  end
  return assemble(run, p, prefix, conv, o.float_conv, excess, o.width, o.minus, zero, sharp)
end

B.define("format", function(run, argv)
  return M.format(run, argv, false)
end)

return M
