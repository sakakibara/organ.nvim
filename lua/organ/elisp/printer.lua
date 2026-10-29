-- Emacs's prin1 and princ (print.c) for elisp values, with print-circle,
-- print-length and print-level nil and print-quoted t.  Every object
-- printed counts against print.c's depth of 200, quote and function short
-- forms excepted, as Emacs.

local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local reader = require("organ.elisp.reader")

local M = {}

local byte = string.byte
local NIL = V.NIL

local PRINT_CIRCLE = 200
local DBL_MIN = 2.2250738585072014e-308

local Q_QUOTE = V.intern("quote")
local Q_FUNCTION = V.intern("function")
local Q_BACKQUOTE = V.intern("`")
local Q_COMMA = V.intern(",")
local Q_COMMA_AT = V.intern(",@")
local Q_ERROR = V.intern("error")

--- Emacs's float_to_string: the shortest of %.15g .. %.17g (from %.1g
--- below DBL_MIN) that reads back as `x`, made to read as a float.
function M.float_string(x)
  if x ~= x then
    R.refuse("nan")
  elseif x == math.huge then
    return "1.0e+INF"
  elseif x == -math.huge then
    return "-1.0e+INF"
  end
  local s
  for prec = math.abs(x) < DBL_MIN and 1 or 15, 17 do
    s = string.format("%." .. prec .. "g", x)
    if tonumber(s) == x then
      break
    end
  end
  if s:match("^[-0-9]*$") then
    s = s .. ".0"
  elseif s:match("^[-0-9]*%.$") then
    s = s .. "0"
  end
  return s
end

local function is_digit(c)
  return c ~= nil and c >= 48 and c <= 57
end

local function is_alpha(c)
  return c ~= nil and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122))
end

local SYMBOL_SPECIAL = "[%z\1-\32\"\\';#(),`%[%]]"

local function symbol_string(name, escape)
  if name == "" then
    return "##"
  end
  if not escape then
    return name
  end
  local c0 = byte(name, 1)
  local signed = (c0 == 45 or c0 == 43) and 1 or 0
  local c1 = byte(name, 1 + signed)
  local confusing = ((is_digit(c1) or c1 == 46) and reader.reads_as_number(name))
    or c0 == 63
    or (c0 == 46 and not is_alpha(byte(name, 2)))
  local out = name:gsub(SYMBOL_SPECIAL, "\\%0"):gsub("\194\160", "\\\194\160")
  if confusing and byte(out, 1) ~= 92 then
    out = "\\" .. out
  end
  return out
end

local function string_literal(s, escape_newlines)
  s = s:gsub('[\\"]', "\\%0")
  if escape_newlines then
    s = s:gsub("[\n\f]", { ["\n"] = "\\n", ["\f"] = "\\f" })
  end
  return '"' .. s .. '"'
end

local function emit(p, s)
  local n = p.n + 1
  p.n = n
  p.out[n] = s
  p.bytes = p.bytes + #s
  p.run:check_string(p.bytes)
end

local function circular()
  R.signal(Q_ERROR, V.list({ V.str("Apparently circular structure being printed") }))
end

local function short_form(obj)
  local cdr = obj.cdr
  if type(cdr) == "table" and cdr.k == "cons" and cdr.cdr == NIL then
    return obj.car, cdr.car
  end
end

local function pr(p, obj, depth)
  while true do
    if depth >= PRINT_CIRCLE then
      circular()
    end
    local run = p.run
    run:step(1)
    if type(obj) == "number" then
      emit(p, string.format("%d", obj))
      return
    end
    local k = obj.k
    if k == "sym" then
      local name = obj.name.s
      run:step(math.floor(#name / 64))
      emit(p, symbol_string(name, p.escape))
      return
    elseif k == "str" then
      if (p.escape or p.strict) and obj.props then
        R.refuse("unprintable", "string with properties")
      end
      run:step(math.floor(#obj.s / 64))
      emit(p, p.escape and string_literal(obj.s, p.escape_newlines) or obj.s)
      return
    elseif k == "flt" then
      emit(p, M.float_string(obj.x))
      return
    elseif k == "big" then
      local s = V.int_to_string(obj)
      run:step(math.floor(#s / 64))
      emit(p, s)
      return
    elseif k == "vec" then
      emit(p, "[")
      for i = 1, obj.n do
        if i > 1 then
          emit(p, " ")
        end
        pr(p, obj[i], depth + 1)
      end
      emit(p, "]")
      return
    elseif k ~= "cons" then
      R.refuse(k == "fn" and "unprintable" or "internal", tostring(k))
    end
    local head, arg = short_form(obj)
    if head == Q_QUOTE or head == Q_FUNCTION then
      emit(p, head == Q_QUOTE and "'" or "#'")
      obj = arg
    elseif head == Q_BACKQUOTE then
      emit(p, "`")
      p.bq = p.bq + 1
      pr(p, arg, depth + 1)
      p.bq = p.bq - 1
      return
    elseif (head == Q_COMMA or head == Q_COMMA_AT) and p.bq > 0 then
      if depth + 1 >= PRINT_CIRCLE then
        circular()
      end
      emit(p, head.name.s)
      p.bq = p.bq - 1
      pr(p, arg, depth + 1)
      p.bq = p.bq + 1
      return
    else
      emit(p, "(")
      pr(p, obj.car, depth + 1)
      local tail = obj.cdr
      while tail ~= NIL do
        if type(tail) == "table" and tail.k == "cons" then
          emit(p, " ")
          pr(p, tail.car, depth + 1)
          tail = tail.cdr
        else
          emit(p, " . ")
          pr(p, tail, depth + 1)
          break
        end
      end
      emit(p, ")")
      return
    end
  end
end

local function print_value(run, v, escape, escape_newlines, strict)
  local p = {
    run = run,
    out = {},
    n = 0,
    bytes = 0,
    bq = 0,
    escape = escape,
    escape_newlines = escape_newlines,
    strict = strict,
  }
  pr(p, v, 0)
  run:charge(p.bytes)
  return table.concat(p.out, "", 1, p.n)
end

--- `prin1-to-string` of `v`; print-escape-newlines when `escape_newlines`.
function M.prin1(run, v, escape_newlines)
  return print_value(run, v, true, escape_newlines)
end

--- `prin1-to-string` of `v` with NOESCAPE; `strict` refuses a string
--- with properties too, as (format "%s" err) of one is not organ's text.
function M.princ(run, v, strict)
  return print_value(run, v, false, false, strict)
end

return M
