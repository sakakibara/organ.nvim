-- Emacs's `read' on a string, restricted to the subset: what Emacs
-- rejects signals as Emacs does, what Emacs accepts outside the subset
-- refuses `syntax' (or `charset' for a character no Unicode string
-- holds).  A port of lread.c's read0, read_char_escape,
-- read_string_literal, read_char_literal, read_integer and
-- string_to_number for a multibyte string source.

local bn = require("organ.calc.bn")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")

local M = {}

local byte = string.byte
local NIL = V.NIL

local NBSP = 0xA0
local CTL = 0x4000000
local META = 0x8000000
local SHIFT = 0x2000000
local BYTE8_LO = 0x3FFF80

local Q_QUOTE = V.intern("quote")
local Q_FUNCTION = V.intern("function")
local Q_BACKQUOTE = V.intern("`")
local Q_COMMA = V.intern(",")
local Q_COMMA_AT = V.intern(",@")
local Q_ERROR = V.intern("error")
local Q_EOF = V.intern("end-of-file")
local Q_INVALID = V.intern("invalid-read-syntax")

local CLOSE_PAREN = {}
local CLOSE_BRACKET = {}
local DOT = {}

local function eof()
  R.signal(Q_EOF, NIL)
end

local function invalid(text)
  R.signal(Q_INVALID, V.list({ V.str(text) }))
end

local function fail(text)
  R.signal(Q_ERROR, V.list({ V.str(text) }))
end

local function is_digit(c)
  return c and c >= 48 and c <= 57
end

-- Characters that end a symbol (besides c <= 32 and NBSP).
local SYMBOL_END = {}
for c in ([["';#()[]`,]]):gmatch(".") do
  SYMBOL_END[byte(c)] = true
end

-- Characters after `.' that make it a dot (besides c <= 32 and NBSP).
local DOT_FOLLOW = {}
for c in ([["';([#?`,]]):gmatch(".") do
  DOT_FOLLOW[byte(c)] = true
end

-- Characters a character literal may be followed by (besides c <= 32).
local CHAR_FOLLOW = {}
for c in ([["';()[]#?`,.]]):gmatch(".") do
  CHAR_FOLLOW[byte(c)] = true
end

local function getc(st)
  local i = st.i
  if i > st.n then
    return -1
  end
  local b = byte(st.s, i)
  if b < 0x80 then
    st.i = i + 1
    return b
  end
  local cp, j = V.utf8_next(st.s, i)
  st.i = j
  return cp
end

-- Digit value of `c` in `base`: -1 when out of range, -2 when no digit.
local function digit_to_number(c, base)
  local d
  if c >= 48 and c <= 57 then
    d = c - 48
  elseif c >= 97 and c <= 122 then
    d = c - 87
  elseif c >= 65 and c <= 90 then
    d = c - 55
  else
    return -2
  end
  return d < base and d or -1
end

local function hexdigit(c)
  if c >= 48 and c <= 57 then
    return c - 48
  elseif c >= 97 and c <= 102 then
    return c - 87
  elseif c >= 65 and c <= 70 then
    return c - 55
  end
  return -1
end

-- Integers

local function digits_to_int(run, digits, neg, base)
  digits = digits:gsub("^0+", "")
  if digits == "" then
    return 0
  end
  if base == 10 and #digits <= 15 then
    local n = tonumber(digits)
    return neg and -n or n
  end
  local b
  if base == 10 then
    run:step(math.ceil(#digits / 64))
    b = bn.from_digits_string(digits)
  else
    local per = math.floor(math.log(1e7) / math.log(base))
    local chunk_base = bn.from_int(base ^ per)
    b = bn.zero()
    local i = 1
    while i <= #digits do
      local piece = digits:sub(i, i + per - 1)
      local scale = #piece == per and chunk_base or bn.from_int(base ^ #piece)
      run:step(#b.d)
      b = bn.add(bn.mul(b, scale), bn.from_int(tonumber(piece, base)))
      i = i + per
    end
  end
  run:charge(8 * #b.d)
  if neg then
    b = bn.neg(b)
  end
  return V.int_from_bn(b)
end

local function decimal_float(int_part, frac, exp_digits, exp_neg)
  local all = int_part .. frac
  local digits = all:gsub("^0+", "")
  if digits == "" then
    return 0.0
  end
  local lead_zeros = #all - #digits
  local ed = exp_digits:gsub("^0+", "")
  local e = #ed > 9 and math.huge or (tonumber(ed) or 0)
  if exp_neg then
    e = -e
  end
  -- The value is 0.DIGITS * 10^mag with a nonzero first digit.
  local mag = e + #int_part - lead_zeros
  if mag > 400 then
    return math.huge
  elseif mag < -400 then
    return 0.0
  end
  if #digits > 780 then
    local sticky = digits:find("[1-9]", 781) and "1" or ""
    digits = digits:sub(1, 780) .. sticky
  end
  return tonumber("0." .. digits .. "e" .. mag)
end

-- The numeric prefix of `s` as Emacs's string_to_number (base 10) scans
-- it, or nil when `s` does not start with a number.
local function scan_number(s)
  local i = 1
  local c = byte(s, 1)
  local neg = c == 45
  if neg or c == 43 then
    i = 2
  end
  local lead_start = i
  while is_digit(byte(s, i)) do
    i = i + 1
  end
  local int_part = s:sub(lead_start, i - 1)
  if byte(s, i) == 46 then
    i = i + 1
  end
  local trail_start = i
  while is_digit(byte(s, i)) do
    i = i + 1
  end
  local frac = s:sub(trail_start, i - 1)
  local e_exp, special = false, nil
  local exp_digits, exp_neg = "", false
  c = byte(s, i)
  if c == 101 or c == 69 then
    local ecp = i
    i = i + 1
    c = byte(s, i)
    if c == 43 or c == 45 then
      exp_neg = c == 45
      i = i + 1
    end
    if is_digit(byte(s, i)) then
      e_exp = true
      local s0 = i
      while is_digit(byte(s, i)) do
        i = i + 1
      end
      exp_digits = s:sub(s0, i - 1)
    elseif byte(s, i - 1) == 43 and s:sub(i, i + 2) == "INF" then
      e_exp, special = true, math.huge
      i = i + 3
    elseif byte(s, i - 1) == 43 and s:sub(i, i + 2) == "NaN" then
      e_exp, special = true, 0 / 0
      i = i + 3
    else
      i = ecp
    end
  end
  local lead = #int_part > 0
  local is_float = #frac > 0 or (lead and e_exp)
  if not is_float and not lead then
    return nil
  end
  return {
    len = i - 1,
    float = is_float,
    neg = neg,
    int_part = int_part,
    frac = frac,
    exp_digits = exp_digits,
    exp_neg = exp_neg,
    special = special,
  }
end

--- Whether all of `s` reads as a number (print.c's test for a symbol
--- name that needs a leading backslash).
function M.reads_as_number(s)
  local n = scan_number(s)
  return n ~= nil and n.len == #s
end

-- The number all of token `s` reads as, or nil.
local function token_number(run, s)
  local n = scan_number(s)
  if not n or n.len ~= #s then
    return nil
  end
  if n.float then
    local x = n.special or decimal_float(n.int_part, n.frac, n.exp_digits, n.exp_neg)
    run:charge(16)
    return V.float(n.neg and -x or x)
  end
  return digits_to_int(run, n.int_part, n.neg, 10)
end

-- Escapes

local SIMPLE_ESCAPES = {
  [97] = 7,
  [98] = 8,
  [100] = 127,
  [101] = 27,
  [102] = 12,
  [110] = 10,
  [114] = 13,
  [116] = 9,
  [118] = 11,
}

local MODIFIER_KEYS = {
  [77] = META,
  [83] = SHIFT,
  [72] = 0x1000000,
  [65] = 0x400000,
  [115] = 0x800000,
}

local function read_char_escape(st, c)
  local modifiers = 0
  local ncontrol = 0
  local chr
  while true do
    if c == -1 then
      eof()
    end
    local simple = SIMPLE_ESCAPES[c]
    local again = false
    if simple then
      chr = simple
    elseif c == 10 then
      fail("Invalid escape char syntax: \\<newline>")
    elseif MODIFIER_KEYS[c] then
      local mod = MODIFIER_KEYS[c]
      local save = st.i
      local c1 = getc(st)
      if c1 ~= 45 then
        if c == 115 then
          st.i = save
          chr = 32
        else
          fail(string.format("Invalid escape char syntax: \\%s not followed by -", string.char(c)))
        end
      else
        modifiers = bit.bor(modifiers, mod)
        c1 = getc(st)
        if c1 == 92 then
          c = getc(st)
          again = true
        else
          chr = c1
        end
      end
    elseif c == 67 or c == 94 then
      if c == 67 and getc(st) ~= 45 then
        fail("Invalid escape char syntax: \\C not followed by -")
      end
      ncontrol = ncontrol + 1
      local c1 = getc(st)
      if c1 == 92 then
        c = getc(st)
        again = true
      else
        chr = c1
      end
    elseif c >= 48 and c <= 55 then
      local i = c - 48
      for _ = 1, 2 do
        local save = st.i
        local d = getc(st)
        if d < 48 or d > 55 then
          st.i = save
          break
        end
        i = i * 8 + (d - 48)
      end
      if i >= 0x80 and i < 0x100 then
        i = i + 0x3FFF00
      end
      chr = i
    elseif c == 120 then
      local i, count = 0, 0
      while true do
        local save = st.i
        local d = getc(st)
        local h = d >= 0 and hexdigit(d) or -1
        if h < 0 then
          st.i = save
          break
        end
        i = i * 16 + h
        if i > 0xFFFFFFF then
          fail(string.format("Hex character out of range: \\x%x...", i))
        end
        if count < 3 then
          count = count + 1
        end
      end
      if count == 0 then
        fail("Invalid escape char syntax: \\x not followed by hex digit")
      end
      if count < 3 and i >= 0x80 then
        i = i + 0x3FFF00
      end
      local low = i % 0x400000
      modifiers = bit.bor(modifiers, i - low)
      chr = low
    elseif c == 117 or c == 85 then
      local count = c == 117 and 4 or 8
      local i = 0
      for _ = 1, count do
        local d = getc(st)
        if d < 0 then
          fail(string.format("Malformed Unicode escape: \\%s%x", string.char(c), i))
        end
        local h = hexdigit(d)
        if h < 0 then
          fail(
            string.format("Non-hex character used for Unicode escape: %s (%d)", V.utf8_char(d), d)
          )
        end
        i = i * 16 + h
      end
      if i > 0x10FFFF then
        fail(string.format("Non-Unicode character: 0x%x", i))
      end
      chr = i
    elseif c == 78 then
      if getc(st) ~= 123 then
        invalid("Expected opening brace after \\N")
      end
      local name = {}
      local white = false
      while true do
        local d = getc(st)
        if d < 0 then
          eof()
        end
        if d == 125 then
          break
        end
        if d >= 0x80 then
          invalid(string.format("Invalid character U+%04X in character name", d))
        end
        if d == 32 or (d >= 9 and d <= 13) then
          if not white then
            name[#name + 1] = " "
            white = true
          end
        else
          white = false
          name[#name + 1] = string.char(d)
        end
        if #name >= 201 then
          invalid("Character name too long")
        end
      end
      if #name == 0 then
        invalid("Empty character name")
      end
      local text = table.concat(name)
      if text:sub(1, 2) ~= "U+" then
        R.refuse("syntax", "\\N{" .. text .. "}")
      end
      -- string_to_number (name + 1, 16): hex digits and an optional dot.
      local hex = text:sub(3):match("^(%x+)%.?$")
      local code = hex and hex:gsub("^0+", "")
      code = code and #code <= 8 and tonumber(code ~= "" and code or "0", 16)
      if not code or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF) then
        invalid("\\N{" .. text .. "}")
      end
      chr = code
    else
      chr = c
    end
    if not again then
      break
    end
  end
  if chr < 0 then
    eof()
  end
  while ncontrol > 0 do
    if (chr >= 64 and chr <= 95) or (chr >= 97 and chr <= 122) then
      chr = chr % 32
    elseif chr == 63 then
      chr = 127
    else
      modifiers = bit.bor(modifiers, CTL)
    end
    ncontrol = ncontrol - 1
  end
  return chr, modifiers
end

-- Literals

local function read_string(st)
  local run = st.run
  local out = {}
  local bytes = 0
  local refusal
  local ch
  while true do
    ch = getc(st)
    if ch < 0 or ch == 34 then
      break
    end
    local skip = false
    local mods = 0
    if ch == 92 then
      ch = getc(st)
      if ch == 115 then
        ch = 32
      elseif ch == 32 or ch == 10 then
        skip = true
      else
        ch, mods = read_char_escape(st, ch)
      end
    end
    if not skip then
      if ch >= BYTE8_LO and ch <= 0x3FFFFF then
        refusal = refusal or { "syntax", "unibyte" }
      elseif ch < 0x80 then
        if mods == CTL and ch == 32 then
          ch, mods = 0, 0
        end
        if bit.band(mods, SHIFT) ~= 0 then
          if ch >= 65 and ch <= 90 then
            mods = mods - SHIFT
          elseif ch >= 97 and ch <= 122 then
            ch = ch - 32
            mods = mods - SHIFT
          end
        end
        if bit.band(mods, META) ~= 0 then
          mods = mods - META
          refusal = refusal or { "syntax", "unibyte" }
        end
      elseif not V.is_scalar(ch) then
        refusal = refusal or { "charset", string.format("0x%X", ch) }
      end
      if mods ~= 0 then
        invalid("Invalid modifier in string")
      end
      if not refusal then
        local piece = V.utf8_char(ch)
        bytes = bytes + #piece
        run:check_string(bytes)
        out[#out + 1] = piece
      end
    end
  end
  if ch < 0 then
    eof()
  end
  if refusal then
    R.refuse(refusal[1], refusal[2])
  end
  run:charge(bytes)
  run:step(1 + math.floor(bytes / 64))
  return V.str(table.concat(out))
end

local function read_char_literal(st)
  local ch = getc(st)
  if ch < 0 then
    eof()
  end
  if ch == 32 or ch == 9 then
    return ch
  end
  local mods = 0
  if ch == 92 then
    ch, mods = read_char_escape(st, getc(st))
  end
  if ch >= BYTE8_LO and ch <= 0x3FFFFF then
    ch = ch - 0x3FFF00
  end
  local save = st.i
  local nch = getc(st)
  st.i = save
  if not (nch <= 32 or CHAR_FOLLOW[nch]) then
    invalid("?")
  end
  if mods ~= 0 then
    R.refuse("syntax", "modifier")
  end
  return ch
end

local function read_integer(st, radix)
  local buf = {}
  local valid = -1
  local before = st.i
  local c = getc(st)
  local neg = false
  if c == 45 or c == 43 then
    neg = c == 45
    before = st.i
    c = getc(st)
  end
  if c == 48 then
    valid = 1
    repeat
      before = st.i
      c = getc(st)
    until c ~= 48
  end
  while c >= 0 do
    local d = digit_to_number(c, radix)
    if d < -1 then
      break
    end
    if d == -1 then
      valid = 0
    elseif valid < 0 then
      valid = 1
    end
    buf[#buf + 1] = string.char(c)
    before = st.i
    c = getc(st)
  end
  st.i = before
  if valid ~= 1 then
    invalid(string.format("integer, radix %d", radix))
  end
  st.run:step(1)
  return digits_to_int(st.run, table.concat(buf):lower(), neg, radix)
end

-- Objects

local read_obj

local function read_symbol(st, c)
  local run = st.run
  local buf = {}
  local quoted = false
  local bytes = 0
  local save
  repeat
    if c == 92 then
      c = getc(st)
      if c < 0 then
        eof()
      end
      quoted = true
    end
    local piece = c < 0x80 and string.char(c) or V.utf8_char(c)
    bytes = bytes + #piece
    run:check_string(bytes)
    buf[#buf + 1] = piece
    save = st.i
    c = getc(st)
  until not (c > 32 and c ~= NBSP and (c >= 128 or not SYMBOL_END[c]))
  st.i = save
  local tok = table.concat(buf)
  run:step(1 + math.floor(bytes / 64))
  local c0 = byte(tok, 1)
  if not quoted and (is_digit(c0) or c0 == 46 or c0 == 45 or c0 == 43) then
    local v = token_number(run, tok)
    if v ~= nil then
      return v
    end
  end
  run:charge(#tok)
  return V.intern(tok)
end

local function read_list(st)
  local run = st.run
  run:enter()
  local first = read_obj(st, "list_start")
  if first == CLOSE_PAREN then
    run:leave()
    return NIL
  end
  local head = V.cons(first, NIL)
  local tail = head
  local n = 1
  run:charge(32)
  while true do
    local x = read_obj(st, "list")
    if x == CLOSE_PAREN then
      break
    elseif x == DOT then
      local cdr = read_obj(st, "dot")
      while true do
        local c = getc(st)
        if c == 59 then
          repeat
            c = getc(st)
          until c < 0 or c == 10
        end
        if c < 0 then
          eof()
        end
        if not (c <= 32 or c == NBSP) then
          if c ~= 41 then
            invalid("expected )")
          end
          break
        end
      end
      tail.cdr = cdr
      break
    else
      n = n + 1
      run:check_list(n)
      run:charge(32)
      local cell = V.cons(x, NIL)
      tail.cdr = cell
      tail = cell
    end
  end
  run:leave()
  return head
end

local function read_vector(st)
  local run = st.run
  run:enter()
  local v = { k = "vec", n = 0 }
  while true do
    local x = read_obj(st, "vector")
    if x == CLOSE_BRACKET then
      break
    end
    local n = v.n + 1
    run:check_list(n)
    run:charge(8)
    v[n] = x
    v.n = n
  end
  run:leave()
  return v
end

local function read_special(st, sym)
  local run = st.run
  run:enter()
  local x = read_obj(st, "special")
  run:leave()
  run:charge(64)
  return V.cons(sym, V.cons(x, NIL))
end

local function read_hash(st)
  local start = st.i - 1
  local function buffered()
    return st.s:sub(start, st.i - 1)
  end
  local function read_and_buffer()
    local c = getc(st)
    if c < 0 then
      invalid(buffered())
    end
    return c
  end
  local ch = read_and_buffer()
  if ch == 39 then
    return read_special(st, Q_FUNCTION)
  elseif ch == 35 then
    R.refuse("syntax", "##")
  elseif ch == 115 then
    if read_and_buffer() ~= 40 then
      invalid(buffered())
    end
    R.refuse("syntax", "#s(")
  elseif ch == 94 then
    ch = read_and_buffer()
    if ch == 94 then
      if read_and_buffer() == 91 then
        R.refuse("syntax", "#^^[")
      end
      invalid(buffered())
    elseif ch == 91 then
      R.refuse("syntax", "#^[")
    end
    invalid(buffered())
  elseif ch == 40 then
    R.refuse("syntax", "#(")
  elseif ch == 91 then
    R.refuse("syntax", "#[")
  elseif ch == 38 then
    R.refuse("syntax", "#&")
  elseif ch == 33 then
    R.refuse("syntax", "#!")
  elseif ch == 120 or ch == 88 then
    return read_integer(st, 16)
  elseif ch == 111 or ch == 79 then
    return read_integer(st, 8)
  elseif ch == 98 or ch == 66 then
    return read_integer(st, 2)
  elseif ch == 64 then
    R.refuse("syntax", "#@")
  elseif ch == 36 then
    R.refuse("syntax", "#$")
  elseif ch == 58 then
    R.refuse("syntax", "#:")
  elseif ch == 95 then
    R.refuse("syntax", "#_")
  elseif ch == 60 then
    R.refuse("syntax", "#<")
  elseif ch >= 48 and ch <= 57 then
    local digits = { string.char(ch) }
    local c
    while true do
      c = read_and_buffer()
      if c < 48 or c > 57 then
        break
      end
      digits[#digits + 1] = string.char(c)
      local d = table.concat(digits):gsub("^0+", "")
      if #d > 19 or (#d == 19 and d > "9223372036854775807") then
        invalid(buffered())
      end
    end
    local d = table.concat(digits):gsub("^0+", "")
    if c == 114 or c == 82 then
      local n = tonumber(d ~= "" and d or "0")
      if n < 2 or n > 36 then
        invalid("integer, radix " .. (d ~= "" and d or "0"))
      end
      return read_integer(st, n)
    end
    local fixnum = #d < 19 or (#d == 19 and d <= "2305843009213693951")
    if fixnum and (c == 61 or c == 35) then
      R.refuse("syntax", c == 61 and "#N=" or "#N#")
    end
    invalid(buffered())
  end
  invalid(buffered())
end

function read_obj(st, where)
  local run = st.run
  while true do
    local c = getc(st)
    if c < 0 then
      eof()
    end
    if c == 40 then
      return read_list(st)
    elseif c == 41 then
      if where == "list_start" or where == "list" then
        return CLOSE_PAREN
      end
      invalid(")")
    elseif c == 91 then
      return read_vector(st)
    elseif c == 93 then
      if where == "vector" then
        return CLOSE_BRACKET
      end
      invalid("]")
    elseif c == 35 then
      return read_hash(st)
    elseif c == 63 then
      run:step(1)
      return read_char_literal(st)
    elseif c == 34 then
      return read_string(st)
    elseif c == 39 then
      return read_special(st, Q_QUOTE)
    elseif c == 96 then
      return read_special(st, Q_BACKQUOTE)
    elseif c == 44 then
      local save = st.i
      if getc(st) == 64 then
        return read_special(st, Q_COMMA_AT)
      end
      st.i = save
      return read_special(st, Q_COMMA)
    elseif c == 59 then
      repeat
        c = getc(st)
      until c < 0 or c == 10
    elseif c > 32 and c ~= NBSP then
      if c == 46 then
        local save = st.i
        local nch = getc(st)
        st.i = save
        if nch <= 32 or nch == NBSP or DOT_FOLLOW[nch] then
          if where == "list" then
            return DOT
          end
          invalid(".")
        end
      end
      return read_symbol(st, c)
    end
  end
end

--- Read one form from byte `pos` of `src`: the value and the byte
--- after it.
function M.read(run, src, pos)
  run:check_string(#src)
  local ok, bad = V.utf8_valid(src)
  if not ok then
    R.refuse("charset", "byte " .. bad)
  end
  local st = { s = src, i = pos or 1, n = #src, run = run }
  local v = read_obj(st, "top")
  return v, st.i
end

return M
