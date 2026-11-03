-- error-message-string (print.c's print_error_message) over the
-- conditions and messages scripts/elisp-data.el records.

local DATA = require("organ.elisp.data.errors")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local printer = require("organ.elisp.printer")

local M = {}

local NIL = V.NIL

function M.conditions(name)
  local e = DATA[name]
  return e and e.conditions
end

--- The error symbol `name`'s entry: { conditions, message, profiles }
--- (`profiles` absent when every profile's features define it).
function M.lookup(name)
  return DATA[name]
end

--- Whether `e` is one of D1a's error kinds as organ.elisp.run raises
--- them: a signal of a known error symbol, a refusal with a listed
--- code, or a limit of a listed cap.
function M.valid(e)
  if type(e) ~= "table" then
    return false
  elseif e.elisp == "signal" then
    local s = e.symbol
    return type(s) == "table"
      and s.k == "sym"
      and not s.uninterned
      and DATA[s.name.s] ~= nil
      and (type(e.data) == "number" or type(e.data) == "table" and e.data.k ~= nil)
  elseif e.elisp == "refused" then
    return R.CODES[e.code] == true
  elseif e.elisp == "limit" then
    return R.DEFAULTS[e.cap] ~= nil
  end
  return false
end

local function has_condition(name, cond)
  for _, c in ipairs(M.conditions(name) or {}) do
    if c == cond then
      return true
    end
  end
  return false
end

local function is_cons(v)
  return type(v) == "table" and v.k == "cons"
end

local function is_string(v)
  return type(v) == "table" and v.k == "str"
end

--- error-message-string of (NAME . DATA), NAME a symbol name.
function M.message(run, name, data, escape_newlines)
  if name == "error" and is_cons(data) and is_string(data.car) and data.cdr == NIL then
    return data.car.s
  end
  local errmsg, tail, file_error
  if name == "error" then
    if not is_cons(data) then
      data = NIL
    end
    errmsg = is_cons(data) and data.car or NIL
    tail = is_cons(data) and data.cdr or NIL
    file_error = false
  else
    local e = DATA[name]
    if not e then
      R.refuse("internal", "no error data for " .. name)
    end
    if e.message and e.message:find("[`']") then
      R.refuse("locale", name)
    end
    errmsg = e.message and V.str(e.message) or NIL
    tail = data
    file_error = has_condition(name, "file-error")
  end
  if file_error and is_cons(tail) then
    errmsg, tail = tail.car, tail.cdr
  end
  local out = {}
  local sep = ": "
  if not is_string(errmsg) then
    out[1] = "peculiar error"
  elseif errmsg.s ~= "" then
    out[1] = errmsg.s
  else
    sep = nil
  end
  local plain = file_error or name == "end-of-file" or name == "user-error"
  local len = #(out[1] or "")
  while is_cons(tail) do
    run:step(1)
    if sep then
      out[#out + 1] = sep
      len = len + #sep
    end
    sep = ", "
    local piece = plain and printer.princ(run, tail.car)
      or printer.prin1(run, tail.car, escape_newlines)
    out[#out + 1] = piece
    len = len + #piece
    run:check_string(len)
    tail = tail.cdr
  end
  return table.concat(out)
end

return M
