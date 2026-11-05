-- Identity and equality (D2): `eq', `eql' and `equal' as Emacs answers
-- them, or a refusal where the answer depends on object sharing organ
-- does not reproduce.
--
-- Two distinct boxes (strings, floats, vectors, integers beyond
-- most-positive-fixnum) that could be one object in Emacs refuse
-- `eq-identity'; boxes that differ in contents are distinct in Emacs
-- too.  Two NaNs compared by contents refuse `nan', as organ keeps no
-- NaN payload and not every NaN's sign; two distinct closures refuse
-- `unprintable'.  `equal' follows fns.c's internal_equal: past depth
-- 10 it remembers the pairs it has seen and past 200 it signals.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local bn = require("organ.calc.bn")
local num = require("organ.elisp.num")

local M = {}

local NIL, T = V.NIL, V.T

local Q_ERROR = V.intern("error")

local function signbit(x)
  return x < 0 or (x == 0 and 1 / x < 0)
end

local function same_float(x, y)
  if x ~= x and y ~= y then
    R.refuse("nan", nil, { x, y })
  end
  return x == y and signbit(x) == signbit(y)
end

-- eq of two values: true, false, or "maybe" when they are distinct
-- boxes that could be one object in Emacs.
local function eq3(run, a, b)
  if a == b then
    return true
  end
  local ta, tb = type(a), type(b)
  if ta ~= "table" or tb ~= "table" or a.k ~= b.k then
    return false
  end
  local k = a.k
  if k == "big" then
    if bn.cmp(a.n, b.n) ~= 0 then
      return false
    end
    return num.emacs_fixnum(a.n) or "maybe"
  elseif k == "flt" then
    local x, y = a.x, b.x
    if x ~= x or y ~= y then
      return (x ~= x and y ~= y) and "maybe" or false
    end
    return (x == y and signbit(x) == signbit(y)) and "maybe" or false
  elseif k == "str" then
    run:step(1 + math.floor(#a.s / 64))
    return a.s == b.s and "maybe" or false
  elseif k == "vec" then
    if a.n ~= b.n then
      return false
    end
    run:step(a.n)
    for i = 1, a.n do
      if eq3(run, a[i], b[i]) == false then
        return false
      end
    end
    return "maybe"
  end
  return false
end
M.eq3 = eq3

--- Whether `a` and `b` are `eq'; refuses `eq-identity' when Emacs's
--- answer depends on sharing.
function M.eq(run, a, b)
  local r = eq3(run, a, b)
  if r == "maybe" then
    R.refuse("eq-identity", nil, { a, b })
  end
  return r
end

--- Whether `a` and `b` are `eql'.
function M.eql(run, a, b)
  if a == b then
    return true
  end
  if type(a) == "table" and a.k == "flt" then
    return type(b) == "table" and b.k == "flt" and same_float(a.x, b.x)
  elseif type(a) == "table" and a.k == "big" then
    return type(b) == "table" and b.k == "big" and bn.cmp(a.n, b.n) == 0
  end
  return M.eq(run, a, b)
end

local function stack_overflow()
  R.signal(Q_ERROR, V.list({ V.str("Stack overflow in equal") }))
end

local function is_cons(v)
  return type(v) == "table" and v.k == "cons"
end

local function equal1(run, o1, o2, depth, ht)
  while true do
    run:step(1)
    if depth > 10 then
      if depth > 200 then
        stack_overflow()
      end
      if type(o1) == "table" and (o1.k == "cons" or o1.k == "vec" or o1.k == "big") then
        local seen = ht[o1]
        if seen then
          if seen[o2] then
            return true
          end
          seen[o2] = true
        else
          ht[o1] = { [o2] = true }
        end
      end
    end
    if o1 == o2 then
      return true
    end
    local t1, t2 = type(o1), type(o2)
    if t1 ~= "table" or t2 ~= "table" or o1.k ~= o2.k then
      return false
    end
    local k = o1.k
    if k == "flt" then
      return same_float(o1.x, o2.x)
    elseif k == "big" then
      return bn.cmp(o1.n, o2.n) == 0
    elseif k == "str" then
      run:step(math.floor(#o1.s / 64))
      return o1.s == o2.s
    elseif k == "vec" then
      if o1.n ~= o2.n then
        return false
      end
      for i = 1, o1.n do
        if not equal1(run, o1[i], o2[i], depth + 1, ht) then
          return false
        end
      end
      return true
    elseif k == "fn" then
      if o1.kind == "closure" and o2.kind == "closure" then
        R.refuse("unprintable", "closure")
      end
      return false
    elseif k ~= "cons" then
      return false
    end
    while is_cons(o1) do
      run:step(1)
      if not is_cons(o2) then
        return false
      end
      if not equal1(run, o1.car, o2.car, depth + 1, ht) then
        return false
      end
      o2 = o2.cdr
      if o1.cdr == o2 then
        return true
      end
      o1 = o1.cdr
    end
    depth = depth + 1
  end
end

--- Whether `a` and `b` are `equal'.
function M.equal(run, a, b)
  return equal1(run, a, b, 0, {})
end

B.define("eq", function(run, argv)
  return M.eq(run, argv[1], argv[2]) and T or NIL
end)

B.define("eql", function(run, argv)
  return M.eql(run, argv[1], argv[2]) and T or NIL
end)

B.define("equal", function(run, argv)
  return M.equal(run, argv[1], argv[2]) and T or NIL
end)

return M
