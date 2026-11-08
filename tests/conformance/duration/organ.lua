-- organ side of the duration conformance gate: reads each item of a case
-- through organ.elisp's reader, calls organ.duration and prints one line
-- per item in the shape emacs.el prints (see NORMALIZE.md).

local M = {}

local OUT_OF_RANGE = "duration out of range"

local function lisp()
  return require("organ.elisp"), require("organ.elisp.value")
end

-- The Lua value organ.duration takes for Lisp datum `v`: a format list
-- becomes the encoding organ.duration documents.
local function to_lua(v)
  local _, V = lisp()
  if type(v) == "number" then
    return v
  elseif v.k == "flt" then
    return v.x
  elseif v.k == "big" then
    return tonumber(V.int_to_string(v))
  elseif v.k == "str" then
    return v.s
  elseif v == V.NIL then
    return nil
  elseif v == V.T then
    return true
  elseif v.k == "sym" then
    return v.name.s
  elseif v.k == "cons" then
    local out = {}
    while v ~= V.NIL do
      local e = v.car
      if type(e) == "table" and e.k == "cons" then
        if type(e.car) == "table" and e.car.k == "str" then
          out[#out + 1] = { e.car.s, e.cdr ~= V.NIL }
        elseif e.car == V.intern("special") then
          local x = to_lua(e.cdr)
          if x == nil then
            x = false
          end
          out[#out + 1] = { special = x }
        else
          error("unsupported format entry")
        end
      else
        out[#out + 1] = to_lua(e)
      end
      v = v.cdr
    end
    return out
  end
  error("unsupported datum")
end

local function printed(v)
  local E = lisp()
  return E.prin1(v, { escape_newlines = true }).value
end

-- The line of a result: `value` made a Lisp value by `wrap`, or the
-- error message `err`.
local function result_line(wrap, value, err)
  if value ~= nil then
    return "=> " .. printed(wrap(value))
  elseif err == OUT_OF_RANGE then
    return "!! out of range"
  end
  local _, V = lisp()
  return "!! " .. printed(V.str(err))
end

--- The output line of one item's source text.
function M.item(src)
  local E, V = lisp()
  local D = require("organ.duration")
  local r = E.read(src)
  if not r.ok then
    error("unreadable item: " .. src)
  end
  local form = r.value
  local head = form.car.name.s
  local args = {}
  local rest = form.cdr
  while rest ~= V.NIL do
    args[#args + 1] = rest.car
    rest = rest.cdr
  end
  if head == "to-minutes" then
    local canonical = args[2] ~= nil and args[2] ~= V.NIL
    return result_line(V.float, D.to_minutes(to_lua(args[1]), canonical))
  elseif head == "p" then
    return "=> " .. printed(D.p(to_lua(args[1])) and V.T or V.NIL)
  elseif head == "from-minutes" then
    local canonical = args[3] ~= nil and args[3] ~= V.NIL
    local fmt = args[2] and to_lua(args[2])
    return result_line(V.str, D.from_minutes(to_lua(args[1]), fmt, canonical))
  elseif head == "h-mm-only-p" then
    local mode = D.h_mm_only_p(to_lua(args[1]) or {})
    return "=> " .. printed(mode and V.intern(mode) or V.NIL)
  end
  error("unknown item " .. head)
end

--- The output text of case text `text`.
function M.render_text(text)
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line ~= "" and line:sub(1, 1) ~= ";" then
      local ok, res = pcall(M.item, line)
      out[#out + 1] = ok and res or ("ORGAN-ERROR: " .. tostring(res):gsub("\n", " "))
    end
  end
  return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

function M.render(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return M.render_text(text)
end

return M
