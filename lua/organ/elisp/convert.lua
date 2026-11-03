-- Conversion between Lua data and elisp values (to_value / to_lua).
-- Shared Lua tables convert to shared values and back; a Lua table
-- reachable from itself refuses `cycle'.

local bn = require("organ.calc.bn")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")

local M = {}

local NIL = V.NIL
local PENDING = {}

local SHAPES = {
  bignum = { bignum = true },
  float = { float = true },
  str = { str = true, props = true },
  sym = { sym = true },
  car = { car = true, cdr = true },
  cdr = { car = true, cdr = true },
  vector = { vector = true },
  fn = { fn = true },
}

local function shape_of(t)
  local shape, n, max = nil, 0, 0
  for key in pairs(t) do
    n = n + 1
    if type(key) == "number" then
      if key < 1 or key % 1 ~= 0 then
        return nil
      end
      max = math.max(max, key)
    elseif type(key) == "string" and SHAPES[key] then
      shape = shape or key
    elseif key ~= "props" then
      return nil
    end
  end
  if shape then
    for key in pairs(t) do
      if not SHAPES[shape][key] then
        return nil
      end
    end
    return shape
  end
  return max == n and "array" or nil
end

--- Whether Lua table `t` is an array without holes.
function M.is_array(t)
  return shape_of(t) == "array"
end

local function check_text(run, s)
  if not V.utf8_valid(s) then
    R.refuse("charset", "invalid UTF-8")
  end
  run:check_string(#s)
  run:charge(#s)
end

local to_value

local function table_value(run, t, memo)
  local shape = shape_of(t)
  if shape == "bignum" then
    local s = t.bignum
    local neg, digits
    if type(s) == "string" then
      neg, digits = s:match("^(%-?)(%d+)$")
    end
    if not digits then
      R.refuse("internal", "to_value: bad bignum")
    end
    run:step(math.ceil(#digits / 64))
    local b = bn.from_digits_string(digits)
    run:charge(8 * #b.d)
    return V.int_from_bn(neg == "-" and bn.neg(b) or b)
  elseif shape == "float" and type(t.float) == "number" then
    run:charge(16)
    return V.float(t.float)
  elseif shape == "str" and type(t.str) == "string" and (t.props == nil or t.props == true) then
    check_text(run, t.str)
    return V.str(t.str, t.props)
  elseif shape == "sym" and type(t.sym) == "string" then
    check_text(run, t.sym)
    return V.intern(t.sym)
  elseif shape == "car" or shape == "cdr" then
    run:charge(32)
    return V.cons(to_value(run, t.car, memo), to_value(run, t.cdr, memo))
  elseif shape == "vector" and type(t.vector) == "table" and shape_of(t.vector) == "array" then
    local v = { k = "vec", n = #t.vector }
    run:check_list(v.n)
    run:charge(8 * v.n)
    for i = 1, v.n do
      v[i] = to_value(run, t.vector[i], memo)
    end
    return v
  elseif shape == "fn" and type(t.fn) == "table" and t.fn.k == "fn" then
    return t.fn
  elseif shape == "array" then
    run:check_list(#t)
    run:charge(32 * #t)
    local items = {}
    for i = 1, #t do
      items[i] = to_value(run, t[i], memo)
    end
    return V.list(items, #t)
  end
  R.refuse("internal", "to_value: unconvertible table")
end

function to_value(run, x, memo)
  run:step(1)
  local tx = type(x)
  if tx == "number" then
    if x % 1 == 0 and math.abs(x) <= V.LUA_INT_MAX then
      return x == 0 and 0 or x
    end
    run:charge(16)
    return V.float(x)
  elseif tx == "string" then
    check_text(run, x)
    return V.str(x)
  elseif tx == "boolean" then
    return x and V.T or NIL
  elseif tx == "nil" then
    return NIL
  elseif tx ~= "table" then
    R.refuse("internal", "to_value: " .. tx)
  end
  local seen = memo[x]
  if seen == PENDING then
    R.refuse("cycle", "table")
  elseif seen then
    return seen
  end
  memo[x] = PENDING
  run:enter()
  local v = table_value(run, x, memo)
  run:leave()
  memo[x] = v
  return v
end

function M.to_value(run, x)
  return to_value(run, x, {})
end

local function bad_value(what)
  R.refuse("internal", "malformed value: " .. what)
end

--- Check value `v` that Lua code built (a consumer's return, a
--- variable, an argument): each box once, charged, well-formed, and
--- reaching no box from itself, as D2 values stay acyclic.
function M.check_value(run, v)
  local state, nodes, pos, top = {}, {}, {}, 0
  local function visit(x)
    if type(x) == "number" then
      if x % 1 ~= 0 or math.abs(x) > V.LUA_INT_MAX then
        bad_value("number " .. tostring(x))
      end
      return
    elseif type(x) ~= "table" then
      bad_value(type(x))
    end
    local st = state[x]
    if st == 1 then
      R.refuse("internal", "malformed value: a cycle")
    elseif st then
      return
    end
    run:step(1)
    local k = x.k
    if k == "str" then
      if type(x.s) ~= "string" then
        bad_value("string")
      end
      check_text(run, x.s)
    elseif k == "sym" then
      if type(x.name) ~= "table" or type(x.name.s) ~= "string" then
        bad_value("symbol")
      elseif not x.uninterned and V.intern(x.name.s) ~= x then
        bad_value("symbol " .. x.name.s)
      end
    elseif k == "flt" then
      if type(x.x) ~= "number" then
        bad_value("float")
      end
    elseif k == "big" then
      if type(x.n) ~= "table" then
        bad_value("bignum")
      end
    elseif k == "fn" then
      if type(x.kind) ~= "string" then
        bad_value("function")
      end
    elseif k == "cons" or k == "vec" then
      if k == "vec" and (type(x.n) ~= "number" or x.n < 0 or x.n % 1 ~= 0) then
        bad_value("vector")
      end
      top = top + 1
      nodes[top], pos[top] = x, 0
    else
      bad_value(tostring(k))
    end
    state[x] = top > 0 and nodes[top] == x and 1 or 2
  end
  visit(v)
  while top > 0 do
    local x = nodes[top]
    local i = pos[top] + 1
    pos[top] = i
    local n = x.k == "cons" and 2 or x.n
    if i > n then
      state[x] = 2
      nodes[top] = nil
      top = top - 1
    elseif x.k == "cons" then
      if i == 1 then
        visit(x.car)
      else
        visit(x.cdr)
      end
    else
      visit(x[i])
    end
  end
  return v
end

local to_lua

local function cons_lua(run, v, memo)
  local items = {}
  local tail = v
  while type(tail) == "table" and tail.k == "cons" do
    run:step(1)
    items[#items + 1] = to_lua(run, tail.car, memo)
    tail = tail.cdr
  end
  if tail == NIL then
    return items
  end
  local out = to_lua(run, tail, memo)
  for i = #items, 1, -1 do
    out = { car = items[i], cdr = out }
  end
  return out
end

function to_lua(run, v, memo)
  run:step(1)
  if type(v) == "number" then
    return v
  end
  local k = v.k
  local seen = memo[v]
  if seen ~= nil then
    return seen
  end
  local out
  if k == "big" then
    out = { bignum = bn.to_string(v.n) }
  elseif k == "flt" then
    out = { float = v.x }
  elseif k == "str" then
    out = v.props and { str = v.s, props = true } or v.s
  elseif v == V.T then
    out = true
  elseif v == NIL then
    out = {}
  elseif k == "sym" then
    out = { sym = v.name.s }
  elseif k == "cons" then
    run:enter()
    out = cons_lua(run, v, memo)
    run:leave()
  elseif k == "vec" then
    run:enter()
    local items = {}
    for i = 1, v.n do
      items[i] = to_lua(run, v[i], memo)
    end
    run:leave()
    out = { vector = items }
  elseif k == "fn" then
    out = { fn = v }
  else
    R.refuse("internal", "to_lua: " .. tostring(k))
  end
  if k == "cons" or k == "vec" then
    memo[v] = out
  end
  return out
end

function M.to_lua(run, v)
  return to_lua(run, v, {})
end

return M
