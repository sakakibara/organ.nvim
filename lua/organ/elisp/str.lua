-- Strings (D5a, D5c): the string builtins, ported from Emacs's fns.c,
-- editfns.c, casefiddle.c, character.c and the subr.el, subr-x.el and
-- mule-util.el definitions, in an org-mode buffer.
--
-- Positions are character indexes in Lisp and byte offsets inside;
-- literal regexp matches and searches land on character boundaries, as
-- UTF-8 is self-synchronizing.  A string derived from one carrying text
-- properties carries them too.  Search is Knuth-Morris-Pratt over bytes,
-- charged one step per 64 byte comparisons.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local bn = require("organ.calc.bn")
local chars = require("organ.elisp.chars")
local num = require("organ.elisp.num")
local syntax = require("organ.elisp.syntax")

local M = {}

local NIL, T = V.NIL, V.T
local wta = B.wta
local define = B.define
local floor = math.floor
local byte, sub = string.byte, string.sub

local Q_ARGS_RANGE = V.intern("args-out-of-range")
local Q_WRONG_LENGTH = V.intern("wrong-length-argument")
local Q_IDENTITY = V.intern("identity")

local MAX_CHAR = 0x3FFFFF

local function is_str(v)
  return type(v) == "table" and v.k == "str"
end

local function is_sym(v)
  return type(v) == "table" and v.k == "sym"
end

local function is_cons(v)
  return type(v) == "table" and v.k == "cons"
end

local function is_vec(v)
  return type(v) == "table" and v.k == "vec"
end

local function arg(argv, i)
  if i <= argv.n then
    return argv[i]
  end
  return NIL
end

local function work(run, bytes)
  run:step(1 + floor(bytes / 64))
end

--- A new string value of UTF-8 `s`, charged and checked against the
--- string cap.
local function new_string(run, s, props)
  run:check_string(#s)
  run:charge(#s)
  return V.str(s, props or nil)
end
M.new_string = new_string

local function check_string(v)
  if not is_str(v) then
    wta("stringp", v)
  end
  return v
end

local function is_char(v)
  return type(v) == "number" and v >= 0 and v <= MAX_CHAR
end

local function check_char(v)
  if not is_char(v) then
    wta("characterp", v)
  end
  return v
end

--- UTF-8 of character `c`; a character outside Unicode scalar values
--- refuses `charset'.
local function char_utf8(c)
  if not V.is_scalar(c) then
    R.refuse("charset", string.format("character %d", c))
  end
  return V.utf8_char(c)
end

--- Emacs's list_length: the length of list `x`, signalling
--- (wrong-type-argument listp TAIL) for a dotted one.
local function list_length(run, x)
  local n, t = 0, x
  while is_cons(t) do
    n = n + 1
    t = t.cdr
  end
  run:step(n)
  if t ~= NIL then
    wta("listp", t)
  end
  return n
end

local function nchars(run, s)
  work(run, #s)
  return V.utf8_len(s)
end

--- Byte offset of character index `i` (0-based) in `s`.
local function byte_of(run, s, i)
  local b = 1
  for _ = 1, i do
    local c = byte(s, b)
    b = b + (c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4)
  end
  work(run, b)
  return b
end

--- Character index (0-based) of byte offset `b` in `s`.
local function char_index(run, s, b)
  work(run, b)
  return V.utf8_len(sub(s, 1, b - 1))
end

--- The code points of `s` as an array.
local function codes_of(run, s)
  local out, i, n = {}, 1, 0
  while i <= #s do
    local c, j = V.utf8_next(s, i)
    n = n + 1
    out[n] = c
    i = j
  end
  work(run, #s)
  return out, n
end

local function next_char_byte(s, b)
  local c = byte(s, b)
  if not c then
    return b + 1
  end
  return b + (c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4)
end

-- Fixnums

--- The value of a fixnum (Emacs's FIXNUMP) as a Lua number, a fixnum
--- beyond 2^53 as an infinity of its sign, or nil for a non-fixnum.
local function fixnum_value(v)
  if type(v) == "number" then
    return v
  elseif type(v) == "table" and v.k == "big" and num.emacs_fixnum(v.n) then
    return v.n.sign > 0 and math.huge or -math.huge
  end
  return nil
end
M.fixnum_value = fixnum_value

--- validate_subarray: 0-based [from, to) of an array of `size`
--- elements, FROM and TO fixnums (negative from the end) or nil.
local function subarray(array, from, to, size)
  local f, t
  local fv = fixnum_value(from)
  if fv then
    f = fv < 0 and fv + size or fv
  elseif from == NIL then
    f = 0
  else
    wta("integerp", from)
  end
  local tv = fixnum_value(to)
  if tv then
    t = tv < 0 and tv + size or tv
  elseif to == NIL then
    t = size
  else
    wta("integerp", to)
  end
  if not (0 <= f and f <= t and t <= size) then
    R.signal(Q_ARGS_RANGE, V.list({ array, from, to }))
  end
  return f, t
end
M.subarray = subarray

-- Calls of the subset's builtins from ports of Lisp definitions.

local function call(run, name, ...)
  local argv = { n = select("#", ...), ... }
  return B.defs[name].fn(run, argv)
end

local function true_of(v)
  return v ~= NIL
end

-- Sequences of characters (concat)

--- UTF-8 pieces of concat_to_string's arguments args[1..n], checked as
--- Emacs checks them before building; returns the pieces, their total
--- bytes and whether a string argument carries properties.
local function concat_pieces(run, args, n)
  local pieces, total, props, bad = {}, 0, false, nil
  local function add_char(c)
    check_char(c)
    if not V.is_scalar(c) then
      bad = bad or c
      return
    end
    local u = V.utf8_char(c)
    pieces[#pieces + 1] = u
    total = total + #u
  end
  for i = 1, n do
    local a = args[i]
    if is_str(a) then
      pieces[#pieces + 1] = a.s
      total = total + #a.s
      props = props or a.props == true
      run:step(1)
    elseif is_vec(a) then
      run:step(a.n)
      for j = 1, a.n do
        add_char(a[j])
      end
    elseif a == NIL then
      run:step(1)
    elseif is_cons(a) then
      list_length(run, a)
      local t = a
      while is_cons(t) do
        add_char(t.car)
        t = t.cdr
      end
    else
      wta("sequencep", a)
    end
  end
  if bad then
    char_utf8(bad)
  end
  return pieces, total, props
end

--- concat of args[1..n] as a new string value.
local function concat(run, args, n)
  local pieces, total, props = concat_pieces(run, args, n)
  run:check_string(total)
  work(run, total)
  return new_string(run, table.concat(pieces), props)
end
M.concat = concat

define("concat", function(run, argv)
  return concat(run, argv, argv.n)
end)

-- Length and characters

--- Flength of a sequence value.
local function length(run, x)
  if is_str(x) then
    return nchars(run, x.s)
  elseif is_cons(x) then
    return list_length(run, x)
  elseif x == NIL then
    return 0
  elseif is_vec(x) then
    return x.n
  elseif type(x) == "table" and x.k == "fn" and x.kind == "closure" then
    R.refuse("unprintable", "length of a function")
  end
  wta("sequencep", x)
end
M.length = length

define("length", function(run, argv)
  return length(run, argv[1])
end)

define("string-to-char", function(run, argv)
  local s = check_string(argv[1]).s
  if s == "" then
    return 0
  end
  return (V.utf8_next(s, 1))
end)

define("char-to-string", function(run, argv)
  return new_string(run, char_utf8(check_char(argv[1])))
end)

define("string", function(run, argv)
  for i = 1, argv.n do
    check_char(argv[i])
  end
  local out = {}
  for i = 1, argv.n do
    out[i] = char_utf8(argv[i])
  end
  run:step(argv.n)
  return new_string(run, table.concat(out))
end)

define("make-string", function(run, argv)
  local len, init = argv[1], argv[2]
  if not (type(len) == "number" and len >= 0) and not (fixnum_value(len) == math.huge) then
    wta("wholenump", len)
  end
  check_char(init)
  local u = char_utf8(init)
  if len == math.huge or type(len) ~= "number" then
    R.limit("string")
  end
  run:check_string(len * #u)
  work(run, len * #u)
  return new_string(run, string.rep(u, len))
end)

--- The elements of sequence `seq` as an array and their count; a dotted
--- list signals as list_length, a function refuses `unprintable'.
local function sequence_items(run, seq)
  local items, n = {}, 0
  if seq == NIL then
    return items, 0
  elseif is_cons(seq) then
    n = list_length(run, seq)
    local t = seq
    for i = 1, n do
      items[i] = t.car
      t = t.cdr
    end
  elseif is_vec(seq) then
    run:step(seq.n)
    for i = 1, seq.n do
      items[i] = seq[i]
    end
    n = seq.n
  elseif is_str(seq) then
    items, n = codes_of(run, seq.s)
  elseif type(seq) == "table" and seq.k == "fn" and seq.kind == "closure" then
    R.refuse("unprintable", "elements of a function")
  else
    wta("sequencep", seq)
  end
  run:check_list(n)
  return items, n
end
M.sequence_items = sequence_items

define("string-to-list", function(run, argv)
  local items, n = sequence_items(run, argv[1])
  run:charge(32 * n)
  return V.list(items, n)
end)

define("string-to-vector", function(run, argv)
  local items, n = sequence_items(run, argv[1])
  run:charge(8 * n)
  local v = { k = "vec", n = n }
  for i = 1, n do
    v[i] = items[i]
  end
  return v
end)

define("substring", function(run, argv)
  local s, from, to = argv[1], arg(argv, 2), arg(argv, 3)
  if is_vec(s) then
    local f, t = subarray(s, from, to, s.n)
    run:step(t - f)
    run:charge(8 * (t - f))
    local v = { k = "vec", n = t - f }
    for i = 1, t - f do
      v[i] = s[f + i]
    end
    return v
  elseif not is_str(s) then
    wta("arrayp", s)
  end
  local f, t = subarray(s, from, to, nchars(run, s.s))
  local bf = byte_of(run, s.s, f)
  local bt = byte_of(run, s.s, t)
  return new_string(run, sub(s.s, bf, bt - 1), s.props)
end)

-- Comparison

local function name_or_string(v)
  if is_sym(v) then
    return v.name
  end
  return check_string(v)
end

local function string_equal(run, argv)
  local a = name_or_string(argv[1])
  local b = name_or_string(argv[2])
  work(run, math.min(#a.s, #b.s))
  return a.s == b.s and T or NIL
end

define("string=", string_equal)
define("string-equal", string_equal)

local function string_lessp(run, a, b)
  a = name_or_string(a)
  b = name_or_string(b)
  work(run, math.min(#a.s, #b.s))
  return a.s < b.s and T or NIL
end

define("string<", function(run, argv)
  return string_lessp(run, argv[1], argv[2])
end)
define("string-lessp", function(run, argv)
  return string_lessp(run, argv[1], argv[2])
end)
define("string>", function(run, argv)
  return string_lessp(run, argv[2], argv[1])
end)
define("string-greaterp", function(run, argv)
  return string_lessp(run, argv[2], argv[1])
end)

--- compare-strings with START1 0 and START2 `start2`, both ends nil
--- unless `len1` (END1 and END2 = len1): t when the parts match,
--- comparing upcased characters when `fold`.
local function compare_strings(run, s1, len1, s2, start2, fold)
  check_string(s1)
  check_string(s2)
  local n1 = nchars(run, s1.s)
  local n2 = nchars(run, s2.s)
  local e1, e2 = n1, n2
  if len1 then
    e1 = math.min(len1, n1)
    e2 = math.min(start2 + len1, n2)
  end
  local c1, c2 = codes_of(run, s1.s), codes_of(run, s2.s)
  local i1, i2 = 0, start2
  while i1 < e1 and i2 < e2 do
    local a, b = c1[i1 + 1], c2[i2 + 1]
    if a ~= b and fold then
      a, b = chars.case_char("upcase", a), chars.case_char("upcase", b)
    end
    if a ~= b then
      return false
    end
    i1, i2 = i1 + 1, i2 + 1
  end
  return i1 >= e1 and i2 >= e2
end

define("string-prefix-p", function(run, argv)
  local prefix, s, fold = argv[1], argv[2], arg(argv, 3) ~= NIL
  local plen = length(run, prefix)
  if plen > length(run, s) then
    return NIL
  end
  return compare_strings(run, prefix, plen, s, 0, fold) and T or NIL
end)

define("string-suffix-p", function(run, argv)
  local suffix, s, fold = argv[1], argv[2], arg(argv, 3) ~= NIL
  local start = length(run, s) - length(run, suffix)
  if start < 0 then
    return NIL
  end
  return compare_strings(run, suffix, nil, s, start, fold) and T or NIL
end)

-- Literal search

local function identity_fold(b)
  return b
end

local ASCII_FOLD = {}
for b = 0, 127 do
  ASCII_FOLD[b] = chars.canon(b)
end

local function ascii_fold(b)
  return ASCII_FOLD[b] or b
end

--- A searcher for byte string `pat`: find(s, from) is the first byte
--- offset >= `from` where `pat` occurs in `s`, or nil; `fold` compares
--- ASCII bytes case-folded.
local function searcher(run, pat, fold)
  local f = fold and ascii_fold or identity_fold
  local m = #pat
  local p = {}
  for i = 1, m do
    p[i] = f(byte(pat, i))
  end
  local fail = { [1] = 0 }
  local k = 0
  for i = 2, m do
    while k > 0 and p[k + 1] ~= p[i] do
      k = fail[k]
    end
    if p[k + 1] == p[i] then
      k = k + 1
    end
    fail[i] = k
  end
  work(run, 2 * m)
  return function(s, from)
    if m == 0 then
      return from <= #s + 1 and from or nil
    end
    local q, ops = 0, 0
    for i = from, #s do
      local c = f(byte(s, i))
      while q > 0 and p[q + 1] ~= c do
        q = fail[q]
        ops = ops + 1
      end
      if p[q + 1] == c then
        q = q + 1
      end
      ops = ops + 1
      if ops >= 4096 then
        work(run, ops)
        ops = 0
      end
      if q == m then
        work(run, ops)
        return i - m + 1
      end
    end
    work(run, ops)
    return nil
  end
end

local function string_search(run, needle, hay, start)
  check_string(needle)
  check_string(hay)
  local from = 1
  if start ~= NIL then
    local sv = fixnum_value(start)
    if not sv then
      wta("fixnump", start)
    end
    local n = nchars(run, hay.s)
    if sv < 0 or sv > n then
      R.signal(Q_ARGS_RANGE, V.list({ start }))
    end
    from = byte_of(run, hay.s, sv)
  end
  local at = searcher(run, needle.s, false)(hay.s, from)
  return at and char_index(run, hay.s, at) or NIL
end

define("string-search", function(run, argv)
  return string_search(run, argv[1], argv[2], arg(argv, 3))
end)

define("string-replace", function(run, argv)
  local from, to, s = argv[1], argv[2], argv[3]
  if is_str(from) and from.s == "" then
    R.signal(Q_WRONG_LENGTH, V.list({ 0 }))
  end
  check_string(from)
  check_string(s)
  local find = searcher(run, from.s, false)
  local parts, n = {}, 0
  local start = 1
  while true do
    local pos = find(s.s, start)
    if not pos then
      break
    end
    if pos ~= start then
      n = n + 1
      parts[n] = new_string(run, sub(s.s, start, pos - 1), s.props)
    end
    n = n + 1
    parts[n] = to
    run:check_list(n)
    start = pos + #from.s
  end
  if n == 0 then
    return s
  end
  if start <= #s.s then
    n = n + 1
    parts[n] = new_string(run, sub(s.s, start), s.props)
  end
  return concat(run, parts, n)
end)

define("string-empty-p", function(run, argv)
  return string_equal(run, { n = 2, argv[1], V.str("") })
end)

local BLANK = { [32] = true, [9] = true, [10] = true, [13] = true }

define("string-blank-p", function(run, argv)
  local s = check_string(argv[1]).s
  work(run, #s)
  for i = 1, #s do
    if not BLANK[byte(s, i)] then
      return NIL
    end
  end
  return 0
end)

-- Regexp arguments (D5c): a literal pattern or a refusal.

local function case_fold(run)
  return require("organ.elisp.eval").case_fold(run)
end

local REGEXP_SPECIAL = "[%[%]%.%*%+%?%^%$\\]"

--- The pattern string a regexp argument builds, as concat builds it
--- around REGEXP in the Lisp definitions (signals as concat does).
local function regexp_text(run, re)
  if is_str(re) then
    return re.s
  end
  return concat(run, { re }, 1).s
end

--- The literal `text` a regexp matches, or a refusal: any regexp
--- special character, or under case folding a non-ASCII character
--- sharing a case class (folding then is the case table's, not ASCII).
local function literal(run, text, fold)
  if text:find(REGEXP_SPECIAL) then
    R.refuse("regexp", text)
  end
  if fold then
    local i = 1
    while i <= #text do
      local c, j = V.utf8_next(text, i)
      if c >= 128 and chars.cased(c) then
        R.refuse("regexp", text)
      end
      i = j
    end
  end
  return text
end

local function fold_eq(a, b, fold)
  if not fold then
    return a == b
  end
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if ascii_fold(byte(a, i)) ~= ascii_fold(byte(b, i)) then
      return false
    end
  end
  return true
end

local function ws_left(s)
  local i = 1
  while BLANK[byte(s, i)] do
    i = i + 1
  end
  return i
end

--- Byte offset after a `\`\(?:RE\)` match at the start of s, or nil
--- (RE nil: the default [ \t\n\r]+).
local function trim_left_end(s, pat, fold)
  if not pat then
    local i = ws_left(s)
    return i > 1 and i or nil
  end
  if fold_eq(sub(s, 1, #pat), pat, fold) then
    return #pat + 1
  end
  return nil
end

--- Byte offset of the leftmost `\(?:RE\)\'` match at or after byte
--- `from`, or nil (RE nil: the default [ \t\n\r]+).
local function trim_right_start(s, pat, fold, from)
  if not pat then
    local i = #s + 1
    while i > from and BLANK[byte(s, i - 1)] do
      i = i - 1
    end
    return i <= #s and i or nil
  end
  local i = #s + 1 - #pat
  if i >= from and fold_eq(sub(s, i), pat, fold) then
    return i
  end
  return nil
end

define("string-trim-left", function(run, argv)
  local s, re = argv[1], arg(argv, 2)
  local text = re ~= NIL and regexp_text(run, re)
  check_string(s)
  local fold = case_fold(run)
  local pat = text and literal(run, text, fold)
  work(run, #s.s)
  local e = trim_left_end(s.s, pat, fold)
  if e then
    return new_string(run, sub(s.s, e), s.props)
  end
  return s
end)

define("string-trim-right", function(run, argv)
  local s, re = argv[1], arg(argv, 2)
  local text = re ~= NIL and regexp_text(run, re)
  check_string(s)
  local fold = case_fold(run)
  local pat = text and literal(run, text, fold)
  work(run, #s.s)
  local i = trim_right_start(s.s, pat, fold, 1)
  if i then
    return new_string(run, sub(s.s, 1, i - 1), s.props)
  end
  return s
end)

define("string-trim", function(run, argv)
  local s, left, right = argv[1], arg(argv, 2), arg(argv, 3)
  local fold = case_fold(run)
  local ltext = left ~= NIL and regexp_text(run, left)
  check_string(s)
  local lpat = ltext and literal(run, ltext, fold)
  work(run, #s.s)
  local beg = trim_left_end(s.s, lpat, fold)
  local rtext = right ~= NIL and regexp_text(run, right)
  local rpat = rtext and literal(run, rtext, fold)
  local e = trim_right_start(s.s, rpat, fold, beg or 1)
  if beg or e then
    return new_string(run, sub(s.s, beg or 1, (e or #s.s + 1) - 1), s.props)
  end
  return s
end)

define("split-string", function(run, argv)
  local s, seps, omit, trim = argv[1], arg(argv, 2), arg(argv, 3), arg(argv, 4)
  local keep_empty = seps ~= NIL and omit == NIL
  length(run, s)
  local ttext = trim ~= NIL and regexp_text(run, trim)
  if seps ~= NIL then
    check_string(seps)
  end
  check_string(s)
  local fold = case_fold(run)
  local tpat = ttext and literal(run, ttext, fold)
  local str = s.s
  local len = #str
  local find
  if seps == NIL then
    find = function(from)
      local i = from
      while i <= len and not (BLANK[byte(str, i)] or byte(str, i) == 12 or byte(str, i) == 11) do
        i = i + 1
      end
      if i > len then
        return nil
      end
      local j = i
      while j <= len and (BLANK[byte(str, j)] or byte(str, j) == 12 or byte(str, j) == 11) do
        j = j + 1
      end
      return i, j
    end
  else
    local pat = literal(run, seps.s, fold)
    local f = searcher(run, pat, fold)
    find = function(from)
      local i = f(str, from)
      return i, i and i + #pat
    end
  end
  work(run, len)
  local acc, n = {}, 0
  local function push(item)
    n = n + 1
    run:check_list(n)
    run:charge(32)
    acc[n] = item
  end
  -- The item s[a, b) trimmed: its value and whether it is non-empty.
  local function trimmed(a, b, whole)
    local item = whole or new_string(run, sub(str, a, b - 1), s.props)
    if not ttext then
      return item, b > a
    end
    local is = item.s
    local ib = trim_left_end(is, tpat, fold) or 1
    local ie = trim_right_start(is, tpat, fold, ib) or #is + 1
    if ib > 1 or ie < #is + 1 then
      item = new_string(run, sub(is, ib, ie - 1), s.props)
    end
    return item, ib < ie
  end
  local start, nxt = 1, 1
  while true do
    run:step(1)
    local sep, sep_end = find(nxt)
    if not sep then
      break
    end
    if keep_empty or start < sep then
      if ttext then
        local item, nonempty = trimmed(start, sep)
        if keep_empty or nonempty then
          push(item)
        end
      else
        push(new_string(run, sub(str, start, sep - 1), s.props))
      end
    end
    nxt = math.max(next_char_byte(str, nxt), sep_end)
    start = sep_end
    if start > len then
      break
    end
  end
  local item
  if start == 1 then
    item = s
    if ttext then
      item = trimmed(1, len + 1, s)
    end
  else
    item = trimmed(start, len + 1)
  end
  if keep_empty or item.s ~= "" then
    push(item)
  end
  return V.list(acc, n)
end)

-- Case conversion (casefiddle.c)

local Q_SIGMA = 0x3A3

local function is_word(c)
  return syntax.lookup("org", c) % 256 == 2
end

-- The string `kind` (upcase, downcase, capitalize, upcase-initials)
-- makes of `s`, a port of do_casify_multibyte_string.
local function case_string(run, s, kind)
  local codes, n = codes_of(run, s)
  local out = {}
  local inword = false
  for i = 1, n do
    local c = codes[i]
    local was = inword
    inword = is_word(c)
    local action
    if kind == "upcase" or kind == "downcase" then
      action = kind
    elseif kind == "capitalize" then
      action = was and "downcase" or "capitalize"
    elseif not was then
      action = "capitalize"
    end
    local piece, changed
    if not action then
      piece, changed = nil, false
    else
      piece = chars.case_special(action, c)
      if piece then
        changed = true
      else
        local m = chars.case_char(action, c)
        changed = m ~= c
        piece = changed and V.utf8_char(m) or nil
      end
    end
    if was and c == Q_SIGMA and changed then
      R.refuse("case-special", "final sigma")
    end
    out[i] = piece or V.utf8_char(c)
  end
  work(run, #s)
  return table.concat(out)
end

local FLAGBITS = 0xFC00000
local TWO32 = 4294967296
local BN_TWO32 = bn.from_int(TWO32)

-- do_casify_natnum, whose `int ch' keeps the low 32 bits of a fixnum.
local function casify_natnum(kind, x)
  local low
  if type(x) == "number" then
    low = x % TWO32
  else
    local m = bn.mod(x.n, BN_TWO32)
    low = V.int_from_bn(m)
  end
  if low > FLAGBITS then
    return x
  end
  local flags = floor(low / 0x400000) * 0x400000
  local c = low - flags
  local m = chars.case_char(kind == "upcase-initials" and "capitalize" or kind, c)
  if m == c then
    return x
  end
  return m + flags
end

local function casify(kind)
  define(kind, function(run, argv)
    local x = argv[1]
    if
      (type(x) == "number" and x >= 0)
      or (type(x) == "table" and x.k == "big" and x.n.sign > 0 and num.emacs_fixnum(x.n))
    then
      return casify_natnum(kind, x)
    elseif not is_str(x) then
      wta("char-or-string-p", x)
    elseif x.s == "" then
      return x
    end
    return new_string(run, case_string(run, x.s, kind), x.props)
  end)
end

casify("upcase")
casify("downcase")
casify("capitalize")
casify("upcase-initials")

-- Mapping

local function funcall(run, f, x)
  return require("organ.elisp.eval").funcall(run, f, { n = 1, x })
end

--- Fmapconcat.
local function mapconcat(run, f, seq, sep)
  local leni = length(run, seq)
  if leni == 0 then
    return new_string(run, "")
  end
  local vals = {}
  if f == Q_IDENTITY and (is_cons(seq) or is_vec(seq)) then
    local items = sequence_items(run, seq)
    for i = 1, leni do
      vals[i] = items[i]
    end
  elseif is_cons(seq) then
    local t = seq
    for i = 1, leni do
      if not is_cons(t) then
        R.refuse("cycle", "list changed while mapping")
      end
      vals[i] = funcall(run, f, t.car)
      t = t.cdr
    end
  elseif is_vec(seq) then
    for i = 1, leni do
      vals[i] = funcall(run, f, seq[i])
    end
  else
    local codes = codes_of(run, seq.s)
    for i = 1, leni do
      vals[i] = funcall(run, f, codes[i])
    end
  end
  local args, n = vals, leni
  if not (sep == NIL or (is_str(sep) and sep.s == "")) then
    args, n = {}, 0
    for i = 1, leni do
      if i > 1 then
        n = n + 1
        args[n] = sep
      end
      n = n + 1
      args[n] = vals[i]
    end
  end
  return concat(run, args, n)
end

define("mapconcat", function(run, argv)
  return mapconcat(run, argv[1], argv[2], arg(argv, 3))
end)

define("string-join", function(run, argv)
  return mapconcat(run, Q_IDENTITY, argv[1], arg(argv, 2))
end)

-- Symbols

define("symbol-name", function(_, argv)
  local s = argv[1]
  if not is_sym(s) then
    wta("symbolp", s)
  end
  return s.name
end)

define("intern", function(run, argv)
  local s, ob = argv[1], arg(argv, 2)
  if is_vec(ob) then
    R.refuse("function", "intern with an obarray")
  elseif ob ~= NIL then
    wta("obarrayp", ob)
  end
  check_string(s)
  if s.props then
    R.refuse("unprintable", "intern of a string with properties")
  end
  work(run, #s.s)
  return V.intern(s.s)
end)

-- Widths (D5c)

--- lisp_string_width of the code points codes[f+1 .. t]: their width,
--- refusing `width' for a character whose width is not fixed across
--- users (and, when `auto_comp`, one automatic composition may join).
local function codes_width(run, codes, f, t, props, auto_comp)
  if props then
    R.refuse("width", "text properties")
  end
  local w = 0
  for i = f + 1, t do
    local c = codes[i]
    local cw = chars.fixed_width(c)
    if not cw or (auto_comp and chars.composes(c)) then
      R.refuse("width", string.format("U+%04X", c))
    end
    w = w + cw
  end
  run:step(1 + floor((t - f) / 64))
  return w
end

--- Fstring_width of a string value over [from, to).
local function string_width(run, s, from, to)
  check_string(s)
  local codes, n = codes_of(run, s.s)
  local f, t = subarray(s, from, to, n)
  return codes_width(run, codes, f, t, s.props, true)
end

define("string-width", function(run, argv)
  return string_width(run, argv[1], arg(argv, 2), arg(argv, 3))
end)

local function lt(run, a, b)
  return true_of(call(run, "<", a, b))
end

define("string-pad", function(run, argv)
  local s, len, padding, start = argv[1], argv[2], arg(argv, 3), arg(argv, 4)
  if call(run, "natnump", len) == NIL then
    wta("natnump", len)
  end
  local pad_len = call(run, "-", len, length(run, s))
  if true_of(call(run, "<=", pad_len, 0)) then
    return s
  end
  local pad = call(run, "make-string", pad_len, padding ~= NIL and padding or 32)
  if start ~= NIL then
    return concat(run, { pad, s }, 2)
  end
  return concat(run, { s, pad }, 2)
end)

define("truncate-string-to-width", function(run, argv)
  local str, end_col = argv[1], argv[2]
  local start_col, padding = arg(argv, 3), arg(argv, 4)
  local ellipsis, ellipsis_prop = arg(argv, 5), arg(argv, 6)
  if start_col == NIL then
    start_col = 0
  end
  if ellipsis ~= NIL and not is_str(ellipsis) then
    R.refuse("locale", "truncate-string-ellipsis")
  end
  local str_len = length(run, str)
  local str_width = string_width(run, str, NIL, NIL)
  local ellipsis_width = ellipsis ~= NIL and string_width(run, ellipsis, NIL, NIL) or 0
  local codes = codes_of(run, str.s)
  local idx, column = 0, 0
  local head_pad, tail_pad = V.str(""), V.str("")
  local last_column, last_idx = NIL, NIL
  local function char_width_at(i)
    local w = chars.fixed_width(codes[i + 1])
    if not w then
      R.refuse("width", string.format("U+%04X", codes[i + 1]))
    end
    return w
  end
  while lt(run, column, start_col) do
    if idx >= str_len then
      idx = str_len
      break
    end
    column = call(run, "+", column, char_width_at(idx))
    idx = idx + 1
  end
  if lt(run, column, start_col) then
    if padding ~= NIL then
      return call(run, "make-string", end_col, padding)
    end
    return new_string(run, "")
  end
  if padding ~= NIL and true_of(call(run, ">", column, start_col)) then
    head_pad = call(run, "make-string", call(run, "-", column, start_col), padding)
  end
  local from_idx = idx
  if true_of(call(run, ">=", end_col, column)) then
    if lt(run, end_col, str_width) and true_of(call(run, ">", str_width, ellipsis_width)) then
      end_col = call(run, "-", end_col, ellipsis_width)
    else
      ellipsis = V.str("")
    end
    while lt(run, column, end_col) do
      last_column, last_idx = column, idx
      if idx >= str_len then
        idx = str_len
        break
      end
      column = call(run, "+", column, char_width_at(idx))
      idx = idx + 1
    end
    if true_of(call(run, ">", column, end_col)) then
      column, idx = last_column, last_idx
    end
    if padding ~= NIL and lt(run, column, end_col) then
      tail_pad = call(run, "make-string", call(run, "-", end_col, column), padding)
    end
  end
  local substring = B.defs.substring.fn
  local function piece(f, t)
    return substring(run, { n = 3, str, f, t })
  end
  if ellipsis_prop ~= NIL and not (is_str(ellipsis) and ellipsis.s == "") and idx ~= NIL then
    local tail = piece(idx, NIL)
    tail = V.str(tail.s, true)
    return concat(run, { head_pad, piece(from_idx, idx), tail }, 3)
  end
  return concat(run, { head_pad, piece(from_idx, idx), tail_pad, ellipsis }, 4)
end)

return M
