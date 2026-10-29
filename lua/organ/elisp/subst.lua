-- org-capture--expand-keyword-in-embedded-elisp: every symbol of a form
-- whose name holds "%:KEY" becomes the value org-store-link-plist holds
-- for :KEY when that is non-nil.  Conses are rebuilt as mapcar does (a
-- dotted list signals as mapcar's length does); vectors and other atoms
-- are kept.
--
-- `plist` is a Lua table mapping keyword names (":link") to values or
-- Lua data, converted as to_value does.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local evaluator = require("organ.elisp.eval")

local M = {}

local NIL = V.NIL

local function is_cons(v)
  return type(v) == "table" and v.k == "cons"
end

-- The key (string-match "%\\(:.*\\)" NAME) finds: from the first "%:"
-- up to the first newline after it, `.' not matching a newline.
local function key_of(name)
  local i = name:find("%:", 1, true)
  if not i then
    return nil
  end
  local j = name:find("\n", i + 1, true)
  return name:sub(i + 1, j and j - 1 or #name)
end

local function subst(run, x, plist, values)
  run:step(1)
  if is_cons(x) then
    local n, t = 0, x
    while is_cons(t) do
      n = n + 1
      t = t.cdr
    end
    if t ~= NIL then
      B.wta("listp", t)
    end
    run:step(n)
    run:charge(32 * n)
    run:enter()
    local items = {}
    t = x
    for i = 1, n do
      items[i] = subst(run, t.car, plist, values)
      t = t.cdr
    end
    run:leave()
    return V.list(items, n)
  elseif type(x) == "table" and x.k == "sym" then
    local name = x.name.s
    run:step(math.floor(#name / 64))
    local key = key_of(name)
    if key then
      local v = values[key]
      if v == nil and plist[key] ~= nil then
        v = evaluator.as_value(run, plist[key])
        values[key] = v
      end
      if v ~= nil and v ~= NIL then
        return v
      end
    end
  end
  return x
end

function M.subst_symbols(run, form, plist)
  if type(plist) ~= "table" then
    R.refuse("internal", "subst_symbols: plist")
  end
  return subst(run, evaluator.as_value(run, form), plist, {})
end

return M
