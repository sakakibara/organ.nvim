local M = {}

-- Lazily required to avoid loading calc + bignum unless a formula
-- actually needs evaluation.
local _calc
local function calc()
  _calc = _calc or require("organ.calc")
  return _calc
end

local function tokenize(s)
  local tokens, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif s:sub(i, i + 1) == "::" then
      tokens[#tokens + 1] = { type = "sep" }
      i = i + 2
    elseif s:sub(i, i + 1) == ".." then
      tokens[#tokens + 1] = { type = "range" }
      i = i + 2
    elseif s:sub(i, i + 1) == "<=" then
      tokens[#tokens + 1] = { type = "cmp", value = "<=" }
      i = i + 2
    elseif s:sub(i, i + 1) == ">=" then
      tokens[#tokens + 1] = { type = "cmp", value = ">=" }
      i = i + 2
    elseif s:sub(i, i + 1) == "==" then
      tokens[#tokens + 1] = { type = "cmp", value = "==" }
      i = i + 2
    elseif s:sub(i, i + 1) == "!=" then
      tokens[#tokens + 1] = { type = "cmp", value = "!=" }
      i = i + 2
    elseif c == "<" then
      tokens[#tokens + 1] = { type = "cmp", value = "<" }
      i = i + 1
    elseif c == ">" then
      tokens[#tokens + 1] = { type = "cmp", value = ">" }
      i = i + 1
    elseif c == "=" then
      tokens[#tokens + 1] = { type = "eq" }
      i = i + 1
    elseif c == "$" then
      tokens[#tokens + 1] = { type = "dollar" }
      i = i + 1
    elseif c == "@" then
      tokens[#tokens + 1] = { type = "at" }
      i = i + 1
    elseif c == "(" then
      tokens[#tokens + 1] = { type = "lparen" }
      i = i + 1
    elseif c == ")" then
      tokens[#tokens + 1] = { type = "rparen" }
      i = i + 1
    elseif c == "," then
      tokens[#tokens + 1] = { type = "comma" }
      i = i + 1
    elseif c:match("[%+%-%*%/%%%^]") then
      tokens[#tokens + 1] = { type = "op", value = c }
      i = i + 1
    elseif c:match("[0-9.]") then
      local j = i
      while j <= #s and s:sub(j, j):match("[0-9.]") do
        -- stop before ".." range operator
        if s:sub(j, j) == "." and s:sub(j + 1, j + 1) == "." then
          break
        end
        j = j + 1
      end
      tokens[#tokens + 1] = { type = "num", value = tonumber(s:sub(i, j - 1)) }
      i = j
    elseif c:match("[%a_]") then
      local j = i
      while j <= #s and s:sub(j, j):match("[%w_]") do
        j = j + 1
      end
      tokens[#tokens + 1] = { type = "ident", value = s:sub(i, j - 1) }
      i = j
    else
      error("formula tokenizer: unexpected char '" .. c .. "' at pos " .. i)
    end
  end
  return tokens
end

-- Parser state.
local Parser = {}
Parser.__index = Parser

function Parser.new(tokens)
  return setmetatable({ tokens = tokens, pos = 1 }, Parser)
end

function Parser:peek(k)
  return self.tokens[self.pos + (k or 0)]
end
function Parser:advance()
  local t = self.tokens[self.pos]
  self.pos = self.pos + 1
  return t
end
function Parser:expect(type)
  local t = self:advance()
  if not t or t.type ~= type then
    error("formula parser: expected " .. type .. " at pos " .. tostring(self.pos - 1))
  end
  return t
end

function Parser:parse_cell_ref()
  local row, col
  local t = self:peek()
  if t and t.type == "at" then
    self:advance()
    row = self:expect("num").value
    if self:peek() and self:peek().type == "dollar" then
      self:advance()
      col = self:expect("num").value
    end
  elseif t and t.type == "dollar" then
    self:advance()
    col = self:expect("num").value
  end
  return { kind = "ref", row = row and math.floor(row), col = col and math.floor(col) }
end

function Parser:parse_ref_or_range()
  local first = self:parse_cell_ref()
  if self:peek() and self:peek().type == "range" then
    self:advance()
    local second = self:parse_cell_ref()
    return {
      kind = "range",
      from = { row = first.row, col = first.col },
      to = { row = second.row, col = second.col },
    }
  end
  return first
end

function Parser:parse_primary()
  local t = self:peek()
  if not t then
    error("formula parser: unexpected end of input")
  end
  if t.type == "num" then
    self:advance()
    return { kind = "num", value = t.value }
  end
  if t.type == "lparen" then
    self:advance()
    local e = self:parse_expr()
    self:expect("rparen")
    return e
  end
  if t.type == "ident" then
    self:advance()
    -- Bare identifier (no parens) — treat as a constant: pi / e.
    if not self:peek() or self:peek().type ~= "lparen" then
      return { kind = "const", name = t.value }
    end
    self:expect("lparen")
    -- Comma-separated argument list. Each argument is a full expression
    -- (which can resolve to a single ref, a range, or a scalar value).
    local args = {}
    if not self:peek() or self:peek().type ~= "rparen" then
      args[#args + 1] = self:parse_expr()
      while self:peek() and self:peek().type == "comma" do
        self:advance()
        args[#args + 1] = self:parse_expr()
      end
    end
    self:expect("rparen")
    -- `arg` (singular) is preserved for backward compat with v* functions
    -- and existing parse-shape tests; `args` is the canonical list form.
    return { kind = "call", name = t.value, args = args, arg = args[1] }
  end
  if t.type == "at" or t.type == "dollar" then
    return self:parse_ref_or_range()
  end
  error("formula parser: unexpected token type '" .. t.type .. "' at pos " .. self.pos)
end

function Parser:parse_unary()
  local t = self:peek()
  if t and t.type == "op" and t.value == "-" then
    self:advance()
    return { kind = "unop", op = "-", arg = self:parse_unary() }
  end
  return self:parse_pow()
end

function Parser:parse_pow()
  local left = self:parse_primary()
  if self:peek() and self:peek().type == "op" and self:peek().value == "^" then
    self:advance()
    -- right-associative: 2^3^4 = 2^(3^4)
    local right = self:parse_unary()
    return { kind = "binop", op = "^", left = left, right = right }
  end
  return left
end

function Parser:parse_term()
  local left = self:parse_unary()
  while
    self:peek()
    and self:peek().type == "op"
    and (self:peek().value == "*" or self:peek().value == "/" or self:peek().value == "%")
  do
    local op = self:advance().value
    local right = self:parse_unary()
    left = { kind = "binop", op = op, left = left, right = right }
  end
  return left
end

function Parser:parse_additive()
  local left = self:parse_term()
  while
    self:peek()
    and self:peek().type == "op"
    and (self:peek().value == "+" or self:peek().value == "-")
  do
    local op = self:advance().value
    local right = self:parse_term()
    left = { kind = "binop", op = op, left = left, right = right }
  end
  return left
end

-- Comparison sits below additive so `1 + 2 < 3 + 4` parses naturally.
-- Returns 1 (true) or 0 (false), never short-circuits.
function Parser:parse_expr()
  local left = self:parse_additive()
  while self:peek() and self:peek().type == "cmp" do
    local op = self:advance().value
    local right = self:parse_additive()
    left = { kind = "cmp", op = op, left = left, right = right }
  end
  return left
end

function Parser:parse_lhs()
  local t = self:peek()
  if t.type == "at" then
    self:advance()
    local row = self:expect("num").value
    if self:peek() and self:peek().type == "dollar" then
      self:advance()
      local col = self:expect("num").value
      return { kind = "cell_formula", row = math.floor(row), col = math.floor(col) }
    end
    return { kind = "row_formula", row = math.floor(row) }
  elseif t.type == "dollar" then
    self:advance()
    local col = self:expect("num").value
    return { kind = "col_formula", col = math.floor(col) }
  end
  error("formula parser: invalid LHS at pos " .. self.pos)
end

function Parser:parse_formula()
  local lhs = self:parse_lhs()
  self:expect("eq")
  local expr = self:parse_expr()
  lhs.expr = expr
  return lhs
end

function Parser:parse_formulas()
  local out = { self:parse_formula() }
  while self:peek() and self:peek().type == "sep" do
    self:advance()
    out[#out + 1] = self:parse_formula()
  end
  return out
end

function M.parse(s)
  local tokens = tokenize(s)
  return Parser.new(tokens):parse_formulas()
end

-- Pull a raw cell, parse to a Calc value if numeric. Returns nil for
-- empty / non-numeric cells so consumers can decide whether to skip
-- (aggregations) or short-circuit (binary ops).
local function cell_value(rows, r, c)
  if not rows[r] then
    return nil
  end
  local cells = rows[r].cells or {}
  local raw = cells[c]
  if not raw then
    return nil
  end
  raw = raw:match("^%s*(.-)%s*$") or ""
  if raw == "" then
    return nil
  end
  -- Plain number first (handles 12, -3, 1.5, 1e3 — fast path).
  local n = tonumber(raw)
  if n then
    return calc().from_number(n)
  end
  -- Fractions and scientific via Calc's parser.
  local ok, v = pcall(calc().from_string, raw)
  if ok then
    return v
  end
  return nil
end

local function collect_range_values(node, ctx)
  if node.kind == "range" then
    local r1, c1 = node.from.row, node.from.col
    local r2, c2 = node.to.row, node.to.col
    local out = {}
    -- One axis must be fixed; the other varies. If both vary, scan all cells in the rectangle.
    if r1 and r2 and c1 and c2 then
      for r = r1, r2 do
        for c = c1, c2 do
          local v = cell_value(ctx.rows, r, c)
          if v ~= nil then
            out[#out + 1] = v
          end
        end
      end
    elseif r1 and r2 then
      -- Column range: c is current_col.
      local c = ctx.current_col
      for r = r1, r2 do
        local v = cell_value(ctx.rows, r, c)
        if v ~= nil then
          out[#out + 1] = v
        end
      end
    elseif c1 and c2 then
      -- Row range: r is current_row.
      local r = ctx.current_row
      for c = c1, c2 do
        local v = cell_value(ctx.rows, r, c)
        if v ~= nil then
          out[#out + 1] = v
        end
      end
    end
    return out
  end
  -- Single ref (treated as 1-element list).
  local r = node.row or ctx.current_row
  local c = node.col or ctx.current_col
  local v = cell_value(ctx.rows, r, c)
  return v == nil and {} or { v }
end

-- ---------------------------------------------------------------------------
-- Function dispatch — every callable in the evaluator goes through here.
-- All inputs and outputs are Calc values; conversion to / from Lua
-- numbers happens at the eval boundary.

local AGG = {
  vsum = function(C, vs)
    return C.vsum(vs)
  end,
  vmean = function(C, vs)
    return C.vmean(vs)
  end,
  vmax = function(C, vs)
    return C.vmax(vs)
  end,
  vmin = function(C, vs)
    return C.vmin(vs)
  end,
  vlen = function(C, vs)
    return C.vlen(vs)
  end,
  vcount = function(C, vs)
    return C.vcount(vs)
  end,
  vmedian = function(C, vs)
    return C.vmedian(vs)
  end,
  vvar = function(C, vs)
    return C.vvar(vs)
  end,
  vsdev = function(C, vs)
    return C.vsdev(vs)
  end,
  vproduct = function(C, vs)
    return C.vproduct(vs)
  end,
  vmaxabs = function(C, vs)
    return C.vmaxabs(vs)
  end,
}

local SCALAR_C = {
  abs = function(C, v)
    return C.abs(v)
  end,
  sqrt = function(C, v)
    return C.sqrt(v)
  end,
  cbrt = function(C, v)
    return C.cbrt(v)
  end,
  exp = function(C, v)
    return C.exp(v)
  end,
  ln = function(C, v)
    return C.ln(v)
  end,
  log = function(C, v)
    return C.ln(v)
  end, -- alias of ln
  log10 = function(C, v)
    return C.log10(v)
  end,
  log2 = function(C, v)
    return C.log2(v)
  end,
  ceil = function(C, v)
    return C.ceil(v)
  end,
  floor = function(C, v)
    return C.floor(v)
  end,
  round = function(C, v)
    return C.round(v)
  end,
  trunc = function(C, v)
    return C.trunc(v)
  end,
  sign = function(C, v)
    return C.from_int(C.sign(v))
  end,
  neg = function(C, v)
    return C.neg(v)
  end,
  sin = function(C, v)
    return C.sin(v)
  end,
  cos = function(C, v)
    return C.cos(v)
  end,
  tan = function(C, v)
    return C.tan(v)
  end,
  asin = function(C, v)
    return C.asin(v)
  end,
  acos = function(C, v)
    return C.acos(v)
  end,
  atan = function(C, v)
    return C.atan(v)
  end,
  sinh = function(C, v)
    return C.sinh(v)
  end,
  cosh = function(C, v)
    return C.cosh(v)
  end,
  tanh = function(C, v)
    return C.tanh(v)
  end,
  sind = function(C, v)
    return C.sin(C.mul(v, C.from_float(math.pi / 180)))
  end,
  cosd = function(C, v)
    return C.cos(C.mul(v, C.from_float(math.pi / 180)))
  end,
  tand = function(C, v)
    return C.tan(C.mul(v, C.from_float(math.pi / 180)))
  end,
  factorial = function(C, v)
    return C.factorial(v)
  end,
  ["not"] = function(C, v)
    return C.lnot(v)
  end,
}

local BINARY_C = {
  pow = function(C, a, b)
    return C.pow(a, b)
  end,
  mod = function(C, a, b)
    return C.mod(a, b)
  end,
  min = function(C, a, b)
    return C.lt(a, b) and a or b
  end,
  max = function(C, a, b)
    return C.gt(a, b) and a or b
  end,
  atan2 = function(C, a, b)
    return C.atan2(a, b)
  end,
  gcd = function(C, a, b)
    return C.gcd(a, b)
  end,
  lcm = function(C, a, b)
    return C.lcm(a, b)
  end,
  binomial = function(C, a, b)
    return C.binomial(a, b)
  end,
  ["and"] = function(C, a, b)
    return C.land(a, b)
  end,
  ["or"] = function(C, a, b)
    return C.lor(a, b)
  end,
}

-- Forward-declared so apply_function can recurse into the Calc-typed
-- evaluator instead of M.eval (which converts back to Lua numbers and
-- would lose Calc identity for further arithmetic).
local eval_calc

local function apply_function(name, args, ctx)
  local C = calc()
  -- Conditional: `if(cond, then, else)`. Evaluates only the chosen branch.
  if name == "if" then
    if #args ~= 3 then
      error("formula: if(cond, a, b) needs exactly 3 args")
    end
    local cond = eval_calc(args[1], ctx)
    if cond == nil then
      return nil
    end
    local taken = C.is_true(cond) and args[2] or args[3]
    return eval_calc(taken, ctx)
  end
  if AGG[name] then
    local arg = args[1]
    if not arg then
      error("formula: " .. name .. " expects a range arg")
    end
    local values = collect_range_values(arg, ctx)
    return AGG[name](C, values)
  end
  if SCALAR_C[name] then
    local v = eval_calc(args[1], ctx)
    if v == nil then
      return nil
    end
    return SCALAR_C[name](C, v)
  end
  if BINARY_C[name] then
    local a = eval_calc(args[1], ctx)
    local b = eval_calc(args[2], ctx)
    if a == nil or b == nil then
      return nil
    end
    return BINARY_C[name](C, a, b)
  end
  error("formula evaluator: unknown function '" .. tostring(name) .. "'")
end

local function const_value(name, ctx)
  -- ctx.vars (when present) lets callers inject symbol bindings ahead
  -- of the built-in constants. Used by M.limit / M.integ / any
  -- consumer that wants to evaluate a symbolic expression at a point.
  if ctx and ctx.vars and ctx.vars[name] ~= nil then
    return ctx.vars[name]
  end
  local C = calc()
  if name == "pi" then
    return C.from_float(math.pi)
  end
  if name == "e" then
    return C.from_float(math.exp(1))
  end
  error("formula: unknown constant '" .. tostring(name) .. "'")
end

-- Internal Calc-typed evaluator. Returns a Calc value or nil on a
-- missing cell / division-by-zero (so consumers can short-circuit).
-- (Forward-declared above for apply_function's recursion.)
function eval_calc(node, ctx)
  local C = calc()
  if node.kind == "num" then
    return C.from_number(node.value)
  end
  if node.kind == "const" then
    return const_value(node.name, ctx)
  end
  if node.kind == "ref" then
    local r = node.row or ctx.current_row
    local c = node.col or ctx.current_col
    return cell_value(ctx.rows, r, c)
  end
  if node.kind == "range" then
    return collect_range_values(node, ctx)
  end
  if node.kind == "unop" then
    local a = eval_calc(node.arg, ctx)
    if a == nil then
      return nil
    end
    return C.neg(a)
  end
  if node.kind == "binop" then
    local a = eval_calc(node.left, ctx)
    local b = eval_calc(node.right, ctx)
    if a == nil or b == nil then
      return nil
    end
    if node.op == "+" then
      return C.add(a, b)
    end
    if node.op == "-" then
      return C.sub(a, b)
    end
    if node.op == "*" then
      return C.mul(a, b)
    end
    if node.op == "/" then
      if C.sign(b) == 0 then
        return nil
      end
      return C.div(a, b)
    end
    if node.op == "%" then
      return C.mod(a, b)
    end
    if node.op == "^" then
      return C.pow(a, b)
    end
    error("formula: unknown binop '" .. tostring(node.op) .. "'")
  end
  if node.kind == "cmp" then
    local a = eval_calc(node.left, ctx)
    local b = eval_calc(node.right, ctx)
    if a == nil or b == nil then
      return nil
    end
    local r
    if node.op == "<" then
      r = C.lt(a, b)
    elseif node.op == "<=" then
      r = C.le(a, b)
    elseif node.op == ">" then
      r = C.gt(a, b)
    elseif node.op == ">=" then
      r = C.ge(a, b)
    elseif node.op == "==" then
      r = C.eq(a, b)
    elseif node.op == "!=" then
      r = not C.eq(a, b)
    else
      error("formula: unknown comparison '" .. tostring(node.op) .. "'")
    end
    return r and C.from_int(1) or C.from_int(0)
  end
  if node.kind == "call" then
    -- Backward compat: older parsed trees stored a single `arg`; current ones
    -- use `args` (array). Translate when only the legacy shape is present.
    local args = node.args
    if not args and node.arg then
      args = { node.arg }
    end
    return apply_function(node.name, args or {}, ctx)
  end
  error("formula evaluator: unknown node kind '" .. tostring(node.kind) .. "'")
end

-- Public API. Returns a Lua number for numeric Calc values, the raw
-- list for ranges, or nil for missing cells / division by zero.
-- Backward-compatible with the pre-Calc evaluator.
function M.eval(node, ctx)
  local v = eval_calc(node, ctx)
  if v == nil then
    return nil
  end
  if type(v) == "table" and v.kind then
    return calc().to_number(v)
  end
  return v
end

-- Calc-typed eval — returns the raw Calc value (preserves rationals,
-- bignums, units). Use this when you want to format with full
-- precision, e.g. "1/3" or "1234567890123456789".
function M.eval_calc(node, ctx)
  return eval_calc(node, ctx)
end

return M
