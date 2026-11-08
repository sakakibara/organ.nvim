local M = {}

-- Lazily required to avoid loading calc + bignum unless a formula
-- actually needs evaluation.
local _calc
local function calc()
  _calc = _calc or require("organ.calc")
  return _calc
end

-- Raised for org syntax organ parses but cannot evaluate. Callers that
-- would otherwise write a result must leave the field alone instead:
-- refusing an unimplemented formula costs the user a message, writing
-- over the field costs them their data.
local function refuse(what)
  error({ refuse = what }, 0)
end

-- The reason string when `err` (from a pcall around parse / eval) is a
-- refusal rather than a genuinely malformed formula, else nil.
function M.refused(err)
  if type(err) == "table" then
    return err.refuse
  end
  if _calc and err == _calc.OVERFLOW then
    return "arithmetic overflow"
  end
  if _calc and type(err) == "string" and err:sub(1, #_calc.SYMBOLIC) == _calc.SYMBOLIC then
    return (err:gsub("^calc: ", ""))
  end
  return nil
end

-- Row / column descriptor after `@` or `$`: an absolute index (`3`),
-- one relative to the current field (`-2`, `+1`), an edge (`<`, `>>`),
-- an hline (`I`, `III`, `-I`), or `#` for the current row / column
-- number.
local function descriptor(s, i)
  return s:match("^#", i)
    or s:match("^<+", i)
    or s:match("^>+", i)
    or s:match("^[%+%-]?I+", i)
    or s:match("^[%+%-]?%d+", i)
end

-- A Calc fraction literal (`1:2`, `1:2:3`) starting at `i`, or nil.
-- Followed by anything that would extend it, the text is not a fraction
-- organ reads, and tokenizes as it always has.
local function fraction_literal(s, i)
  local text = s:match("^%d+:%d+:%d+", i) or s:match("^%d+:%d+", i)
  if not text or s:find("^[%w_.:#@$]", i + #text) then
    return nil
  end
  return text
end

local function tokenize(s)
  -- Emacs substitutes `@#` and `$#` as bare digits before Calc reads the
  -- formula, so a colon beside one builds a fraction from the row or
  -- column number.
  if s:find(":[@$]#") or s:find("[@$]#:") then
    refuse("':' next to '@#' or '$#'")
  end
  local tokens, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    local fraction = fraction_literal(s, i)
    if fraction then
      tokens[#tokens + 1] = { type = "frac", value = calc().from_fraction(fraction) }
      i = i + #fraction
    elseif c:match("%s") then
      i = i + 1
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
    elseif c == "$" or c == "@" then
      local d = descriptor(s, i + 1)
      if not d then
        error("formula tokenizer: missing descriptor after '" .. c .. "' at pos " .. i)
      end
      tokens[#tokens + 1] = { type = c == "$" and "dollar" or "at", desc = d }
      i = i + 1 + #d
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
      local exponent = s:match("^[eE][%+%-]?%d+", j)
      if exponent then
        j = j + #exponent
      end
      local text = s:sub(i, j - 1)
      local value = tonumber(text)
      if not value then
        error("formula tokenizer: malformed number '" .. text .. "' at pos " .. i)
      end
      tokens[#tokens + 1] = { type = "num", value = value, float = text:find("[%.eE]") ~= nil }
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

-- Absolute descriptors keep their plain numeric `row` / `col` field so
-- consumers of the parsed tree see the shape they always have; every
-- other form resolves against the table at evaluation time.
local function ref_part(node, key, desc)
  node[key .. "_desc"] = desc
  node[key] = desc:match("^%d+$") and tonumber(desc) or nil
end

function Parser:parse_cell_ref()
  local node = { kind = "ref" }
  local t = self:peek()
  if t and t.type == "at" then
    self:advance()
    ref_part(node, "row", t.desc)
    if self:peek() and self:peek().type == "dollar" then
      ref_part(node, "col", self:advance().desc)
    end
  elseif t and t.type == "dollar" then
    self:advance()
    ref_part(node, "col", t.desc)
  end
  return node
end

local function range_end(ref)
  return {
    row = ref.row,
    col = ref.col,
    row_desc = ref.row_desc,
    col_desc = ref.col_desc,
  }
end

function Parser:parse_ref_or_range()
  local first = self:parse_cell_ref()
  if self:peek() and self:peek().type == "range" then
    self:advance()
    local second = self:parse_cell_ref()
    return { kind = "range", from = range_end(first), to = range_end(second) }
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
    return { kind = "num", value = t.value, float = t.float }
  end
  if t.type == "frac" then
    self:advance()
    return { kind = "frac", value = t.value }
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

function Parser:parse_product()
  local left = self:parse_unary()
  while self:peek() and self:peek().type == "op" and self:peek().value == "*" do
    self:advance()
    local right = self:parse_unary()
    left = { kind = "binop", op = "*", left = left, right = right }
  end
  return left
end

-- Calc binds `*` tighter than `/` and `%`, so `a/b*c` is `a/(b*c)`
-- while `a*b/c` stays `(a*b)/c`.
function Parser:parse_term()
  local left = self:parse_product()
  while
    self:peek()
    and self:peek().type == "op"
    and (self:peek().value == "/" or self:peek().value == "%")
  do
    local op = self:advance().value
    local right = self:parse_product()
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
  if not t then
    error("formula parser: empty LHS")
  end
  if t.type == "at" then
    self:advance()
    local node = { kind = "row_formula" }
    ref_part(node, "row", t.desc)
    if self:peek() and self:peek().type == "dollar" then
      node.kind = "cell_formula"
      ref_part(node, "col", self:advance().desc)
    end
    return node
  elseif t.type == "dollar" then
    self:advance()
    local node = { kind = "col_formula" }
    ref_part(node, "col", t.desc)
    return node
  end
  error("formula parser: invalid LHS at pos " .. self.pos)
end

local function parse_lhs_text(s)
  local p = Parser.new(tokenize(s))
  local lhs = p:parse_lhs()
  if p:peek() then
    error("formula parser: trailing input in LHS")
  end
  return lhs
end

local function parse_expr_text(s)
  local p = Parser.new(tokenize(s))
  local expr = p:parse_expr()
  local t = p:peek()
  if t then
    error("formula parser: unexpected token type '" .. t.type .. "' at pos " .. p.pos)
  end
  return expr
end

-- The mode string after a formula's last `;`, scanned as Emacs scans
-- it: every `[pnfse]` with digits comes out first, then each flag letter
-- left to right, wherever it stands, and what is left is a printf
-- template (`;N%.2f`, `;%.1f%%`). So a template letter that is a flag
-- is a flag: `;%d items` sets `t` and prints `%d iems`.
local CONVERSION = "%%[-+ #0]*%d*%.?%d*([diouxXeEfgGs])"

local DURATION = { t = "hours", T = "hh:mm:ss", U = "hh:mm" }

local function parse_mode(s)
  local mode = {}
  local precision = s:match("[pnfse]%-?%d+")
  if precision then
    refuse("unsupported formula mode flag '" .. precision .. "'")
  end
  -- The last of `R` / `D`, and of `t` / `T` / `U`, wins.
  local fmt = s:gsub("[tTUNLEDRFSu]", function(flag)
    if DURATION[flag] then
      mode.duration = DURATION[flag]
    elseif flag == "N" then
      mode.numeric = true
    elseif flag == "R" then
      mode.radians = true
    elseif flag == "D" then
      mode.radians = false
    else
      refuse("unsupported formula mode flag '" .. flag .. "'")
    end
    return ""
  end)
  if fmt:match("%S") then
    mode.conv = fmt:gsub("%%%%", ""):match("^[^%%]*" .. CONVERSION .. "[^%%]*$")
    if not mode.conv then
      refuse("unsupported printf format '" .. fmt .. "'")
    end
    mode.fmt = fmt
  end
  return mode
end

-- Emacs gives Calc no say over a duration formula whose text is a bare
-- `H:M` or `H:M:S`: that text is the result.
local function duration_literal(text)
  if text:match("^%d+:%d+$") or text:match("^%d+:%d+:%d+$") then
    return text
  end
  return nil
end

-- One entry per `::`-separated formula. A bad LHS raises (Emacs
-- `Unknown field`); a bad RHS yields an `error` node so evaluation
-- writes #ERROR into that formula's target cells only. Valid org that
-- organ does not implement raises a refusal instead, so the caller can
-- leave the fields alone rather than overwrite them.
function M.parse(s)
  local out = {}
  for seg in (s .. "::"):gmatch("(.-)::") do
    if seg:match("%S") then
      local lhs_s, rhs_s = seg:match("^%s*([^=]-)%s*=(.*)$")
      if not lhs_s then
        error("formula parser: missing '=' in '" .. seg .. "'")
      end
      local ok, fm = pcall(parse_lhs_text, lhs_s)
      if not ok then
        if M.refused(fm) then
          error(fm, 0)
        end
        error("formula parser: invalid LHS '" .. lhs_s .. "'")
      end
      -- Emacs takes the mode from after the last `;`; one left in the
      -- expression is a syntax error there.
      local expr_s, mode_s = rhs_s:match("^(.*);(.*)$")
      if mode_s then
        for k, v in pairs(parse_mode(mode_s)) do
          fm[k] = v
        end
        -- Emacs strips the spaces after `=`, and nothing else.
        fm.literal = fm.duration and duration_literal((expr_s:gsub("^ *", ""))) or nil
      end
      local ok_rhs, expr = pcall(parse_expr_text, expr_s or rhs_s)
      if not ok_rhs and M.refused(expr) then
        error(expr, 0)
      end
      fm.expr = ok_rhs and expr or { kind = "error", message = tostring(expr) }
      out[#out + 1] = fm
    end
  end
  return out
end

-- Calc reads these as infinities, not as variables, and organ has no
-- value for them.
local NOT_A_VARIABLE = { inf = true, nan = true, uinf = true }

-- Emacs integers are exact at any size; a Lua number is only below 2^53.
local EXACT = 2 ^ 53

local function in_range(x)
  if not (math.abs(x) < EXACT) then
    refuse("a duration past 2^53 seconds")
  end
  return x
end

-- Emacs's `string-to-number`: the number `text` starts with after
-- blanks, else 0, and whether that is an integer.
local function read_number(text)
  local reader = require("organ.elisp.reader")
  local n = reader.scan_number(text:match("^[ \t]*(.*)$"))
  if not n then
    return 0, true
  end
  if n.float then
    local x = n.special or reader.decimal_float(n.int_part, n.frac, n.exp_digits, n.exp_neg)
    return n.neg and -x or x, false
  end
  local x = tonumber(n.int_part)
  return (n.neg and x ~= 0) and -x or x, true
end

-- `org-ts-regexp-both`: an active or inactive timestamp anywhere in `s`.
local function holds_timestamp(s)
  return s:find("[%[<]%d%d%d%d%-%d%d%-%d%d[%]>]") ~= nil
    or s:find("[%[<]%d%d%d%d%-%d%d%-%d%d .-[%]>]") ~= nil
end

-- `org-table-time-string-to-seconds`: the first `H:M:S` in `s`, else its
-- first `H:M` unless `s` holds a timestamp, else the number `s` starts
-- with. A second result marks an integer.
local function time_seconds(s)
  local minus, h, m, sec = s:match("(%-?)(%d+):(%d+):(%d+)")
  if not h and not holds_timestamp(s) then
    minus, h, m = s:match("(%-?)(%d+):(%d+)")
  end
  if not h then
    return read_number(s)
  end
  local total = in_range(tonumber(h)) * 3600 + in_range(tonumber(m)) * 60
  total = in_range(total + (sec and in_range(tonumber(sec)) or 0))
  return (minus == "-" and total ~= 0) and -total or total, true
end

-- A field under a duration flag: its seconds, as the integer or float
-- Emacs hands Calc. Never a fraction.
local function duration_field(raw)
  local x, int = time_seconds(raw)
  if int then
    return calc().from_int(in_range(x))
  end
  if x ~= x or x == math.huge or x == -math.huge then
    refuse("a duration field past the range organ holds")
  end
  return calc().from_float(x)
end

-- Pull a raw cell, parse to a Calc value: a number, or a symbol when
-- the field is spelled like a name. Returns nil for empty cells and
-- for text Calc would have to parse, so consumers can decide whether
-- to skip (aggregations) or short-circuit (binary ops); under `;N`
-- and the duration flags every field reads as a number, empty and
-- textual alike, except that an empty field in a range (`ranged`) is
-- dropped, as Emacs drops it. A second result marks a Calc fraction
-- (`1:2`), which puts the evaluation in a fraction context.
local function cell_value(ctx, r, c, ranged)
  local row = ctx.rows[r]
  local raw = row and (row.cells or {})[c]
  raw = raw and (raw:match("^%s*(.-)%s*$") or "")
  if ranged and (raw == nil or raw == "") then
    return nil
  end
  if ctx.duration and raw and raw ~= "" then
    return duration_field(raw)
  end
  if raw and raw ~= "" then
    -- Integers stay exact; anything with a point or exponent is a
    -- float, as Calc reads it.
    if raw:match("^[+-]?%d+$") then
      return calc().from_string(raw)
    end
    local n = tonumber(raw)
    if n then
      return calc().from_float(n)
    end
    -- A field spelled like a Calc variable reads as that symbol, so a
    -- formula over a text column stays algebraic instead of failing.
    if not ctx.numeric and raw:match("^%a[%w_]*$") and not NOT_A_VARIABLE[raw] then
      return calc().sym(raw)
    end
    -- Under `;N` Emacs reads field text with `string-to-number`, so no
    -- field is a fraction there.
    if not ctx.numeric then
      local fraction = calc().from_fraction(raw)
      if fraction then
        ctx.fraction = true
        return fraction, true
      end
    end
    local ok, v = pcall(calc().from_string, raw)
    if ok and not (ctx.numeric and calc().is_symbol(v)) then
      -- `1/2` is a quotient, which Calc takes with Fraction mode off.
      if v.kind == "rat" then
        return calc().from_float(calc().to_number(v))
      end
      return v
    end
  end
  if row and (ctx.numeric or ctx.duration) then
    return calc().from_int(0)
  end
  return nil
end

-- Resolve a row descriptor to a data-row index. `last` marks a range's
-- upper end, where an hline stands for the row above it rather than
-- the one below, so `@I..@II` is the block between the two hlines.
local function resolve_row(desc, ctx, last)
  if not desc then
    return ctx.current_row
  end
  if desc:match("^%d+$") then
    return tonumber(desc)
  end
  if desc:match("^[%+%-]%d+$") then
    return ctx.current_row + tonumber(desc)
  end
  if desc:match("^<+$") then
    return #desc
  end
  if desc:match("^>+$") then
    return #ctx.rows - #desc + 1
  end
  local sign, hlines = desc:match("^([%+%-]?)(I+)$")
  if sign == "" then
    local below = (ctx.hlines or {})[#hlines] or (#ctx.rows + 1)
    return last and below - 1 or below
  end
  refuse("unsupported row descriptor '@" .. desc .. "'")
end

local function resolve_col(desc, ctx)
  if not desc then
    return ctx.current_col
  end
  if desc:match("^%d+$") then
    return tonumber(desc)
  end
  if desc:match("^[%+%-]%d+$") then
    return ctx.current_col + tonumber(desc)
  end
  if desc:match("^<+$") then
    return #desc
  end
  if desc:match("^>+$") then
    return (ctx.ncols or 0) - #desc + 1
  end
  refuse("unsupported column descriptor '$" .. desc .. "'")
end

-- A target descriptor and whether it was written as an absolute index.
local function target_index(desc, extent, axis)
  if desc:match("^%d+$") then
    return tonumber(desc), true
  end
  if desc:match("^<+$") then
    return #desc, false
  end
  if desc:match("^>+$") then
    return extent - #desc + 1, false
  end
  refuse("unsupported formula target '" .. axis .. desc .. "'")
end

-- Row / column a formula assigns to, resolved against the table's
-- geometry. An edge descriptor (`@>`, `$<<`) has to land on a row or
-- column that exists; an absolute `$N` past the last column still
-- creates it, the way org does. An hline-relative target, a row offset
-- or `@#` refuses -- Emacs declines to assign to those too.
function M.resolve_target(fm, ctx)
  local nrows, ncols = #ctx.rows, ctx.ncols or 0
  local row, col
  if fm.row_desc then
    row = target_index(fm.row_desc, nrows, "@")
    if row < 1 or row > nrows then
      refuse("formula target '@" .. fm.row_desc .. "' is outside the table")
    end
  end
  if fm.col_desc then
    local absolute
    col, absolute = target_index(fm.col_desc, ncols, "$")
    if col < 1 or (not absolute and col > ncols) then
      refuse("formula target '$" .. fm.col_desc .. "' is outside the table")
    end
  end
  return row, col
end

local function collect_range_values(node, ctx)
  if node.kind ~= "range" then
    -- Single ref (treated as 1-element list).
    local v = cell_value(ctx, resolve_row(node.row_desc, ctx), resolve_col(node.col_desc, ctx))
    return v == nil and {} or { v }
  end
  local from, to = node.from, node.to
  local rows_span = from.row_desc and to.row_desc
  local cols_span = from.col_desc and to.col_desc
  local r1, r2 = resolve_row(from.row_desc, ctx), resolve_row(to.row_desc, ctx, true)
  local c1, c2 = resolve_col(from.col_desc, ctx), resolve_col(to.col_desc, ctx)
  local out = {}
  -- One axis must be fixed; the other varies. If both vary, scan all cells in the rectangle.
  if not rows_span then
    r1, r2 = ctx.current_row, ctx.current_row
  end
  if not cols_span then
    c1, c2 = ctx.current_col, ctx.current_col
  end
  if rows_span or cols_span then
    for r = r1, r2 do
      for c = c1, c2 do
        local v = cell_value(ctx, r, c, true)
        if v ~= nil then
          out[#out + 1] = v
        end
      end
    end
  end
  return out
end

-- Fraction context. An evaluation that reads a Calc fraction, from a
-- field or a literal, sets `ctx.fraction`; only then does a rat survive
-- from one application into the next. An application over a fraction
-- answers only where organ's exact arithmetic is Calc's, and refuses
-- otherwise: Calc floats a fraction to its own 12 digits, which a
-- double does not reproduce.

local function is_fraction(v)
  return type(v) == "table" and v.kind == "rat"
end

-- Whether any of `values` -- Calc values or vectors of them -- holds a
-- fraction. Always false outside a fraction context.
local function over_fraction(ctx, values)
  if not (ctx and ctx.fraction) then
    return false
  end
  for _, v in ipairs(values) do
    if is_fraction(v) then
      return true
    end
    if type(v) == "table" and not v.kind then
      for _, item in ipairs(v) do
        if is_fraction(item) then
          return true
        end
      end
    end
  end
  return false
end

-- Refuses `name` unless every one of `values` is an integer or a
-- fraction.
local function exact_only(name, values)
  for _, v in ipairs(values) do
    if not calc().is_exact(v) then
      refuse(name .. "() of a fraction")
    end
  end
end

local FRACTION_BINARY = {
  ["+"] = function(C, a, b)
    return C.add(a, b)
  end,
  ["-"] = function(C, a, b)
    return C.sub(a, b)
  end,
  ["*"] = function(C, a, b)
    return C.mul(a, b)
  end,
  ["/"] = function(C, a, b)
    if C.sign(b) == 0 then
      return C.fdiv(a, b)
    end
    return C.div(a, b)
  end,
  ["^"] = function(C, a, b)
    if not C.is_int(b) then
      refuse("^() of a fraction")
    end
    return C.pow(a, b)
  end,
}

-- One-argument functions Calc also answers with a second argument; any
-- other one gets the call back unevaluated, as Calc writes it.
local SECOND_ARGUMENT = {
  round = "digits",
  floor = "digits",
  ceil = "digits",
  trunc = "digits",
  log = true,
  sign = true,
  ["not"] = true,
}

local FRACTION_AGG = { vsum = true, vmax = true, vmin = true, vcount = true }
local FRACTION_SCALAR = { abs = true, floor = true, ceil = true, round = true, trunc = true }

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

-- Calc's angular mode. A table formula computes in Degrees; `;R` asks
-- for Radians. `sind` / `cosd` / `tand` are organ's own spellings and
-- stay in degrees under either.
local DEGREE = math.pi / 180

-- Where Calc has an exact answer, indexed by the argument's quarter
-- turn. `false` is a pole: the tangent has no value there, so the call
-- stands instead of the 1.6e16 a trip through radians would give.
local QUADRANT = {
  sin = { 0, 1, 0, -1 },
  cos = { 1, 0, -1, 0 },
  tan = { 0, false, 0, false },
}

local function radians_mode(ctx)
  return ctx ~= nil and ctx.radians == true
end

-- The exact answer `q` quarter turns round, in the argument's own
-- exactness; nil where the function has no value at that angle.
local function on_axis(C, name, v, q)
  local exact = QUADRANT[name][q % 4 + 1]
  if exact == false then
    return nil
  end
  return C.is_float(v) and C.from_float(exact) or C.from_int(exact)
end

local function degree_trig(C, name, v)
  local x = C.to_number(v)
  local q = x / 90
  if math.abs(q) < 2 ^ 53 and q == math.floor(q) then
    return on_axis(C, name, v, q)
  end
  return C[name](C.from_float(x * DEGREE))
end

local function trig(C, name, v, ctx)
  if not radians_mode(ctx) then
    return degree_trig(C, name, v)
  end
  if C.to_number(v) == 0 then
    return on_axis(C, name, v, 0)
  end
  return C[name](v)
end

local function inverse_trig(C, r, ctx)
  if radians_mode(ctx) then
    return r
  end
  return C.from_float(C.to_number(r) / DEGREE)
end

-- Calc answers these with a complex pair. organ has no complex tower,
-- so it declines rather than write a real number that is not the
-- answer: a refused formula leaves every field as the user left it.
local function real_only(C, v, what)
  if C.sign(v) < 0 then
    refuse(what)
  end
end

-- Calc's principal root of a negative base is complex whenever the
-- exponent is not a whole number, `(-8)^(1/3)` included.
local function power(C, a, b)
  if not (C.is_symbolic(a) or C.is_symbolic(b)) and C.sign(a) < 0 and not C.is_whole(b) then
    refuse("a fractional power of a negative number")
  end
  return C.pow(a, b)
end

-- The angle whose sine / cosine / tangent is exact, by argument, in
-- degrees. Calc is exact only at these three points, and only for an
-- exact argument; in Radians mode only the zero angle survives.
local INVERSE_EXACT = {
  arcsin = { [-1] = -90, [0] = 0, [1] = 90 },
  arccos = { [-1] = 180, [0] = 90, [1] = 0 },
  arctan = { [-1] = -45, [0] = 0, [1] = 45 },
}

local function inverse_on_axis(C, name, v, ctx)
  if not C.is_int(v) then
    return nil
  end
  local degrees = INVERSE_EXACT[name][C.to_number(v)]
  if degrees == nil then
    return nil
  end
  if radians_mode(ctx) and degrees ~= 0 then
    return nil
  end
  return C.from_int(radians_mode(ctx) and 0 or degrees)
end

-- `arcsin` and `arccos` have no real value outside -1..1, where Calc
-- answers with a complex pair.
local function bounded_inverse(C, name, fn, v, ctx)
  if math.abs(C.to_number(v)) > 1 then
    refuse(name .. "() outside -1..1")
  end
  return inverse_on_axis(C, name, v, ctx) or inverse_trig(C, fn(v), ctx)
end

local SCALAR_C = {
  abs = function(C, v)
    return C.abs(v)
  end,
  sqrt = function(C, v)
    real_only(C, v, "sqrt() of a negative number")
    return C.sqrt(v)
  end,
  cbrt = function(C, v)
    return C.cbrt(v)
  end,
  exp = function(C, v)
    return C.exp(v)
  end,
  ln = function(C, v)
    real_only(C, v, "ln() of a negative number")
    return C.ln(v)
  end,
  log = function(C, v)
    real_only(C, v, "log() of a negative number")
    return C.ln(v)
  end, -- alias of ln
  log10 = function(C, v)
    real_only(C, v, "log10() of a negative number")
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
  sin = function(C, v, ctx)
    return trig(C, "sin", v, ctx)
  end,
  cos = function(C, v, ctx)
    return trig(C, "cos", v, ctx)
  end,
  tan = function(C, v, ctx)
    return trig(C, "tan", v, ctx)
  end,
  asin = function(C, v, ctx)
    return inverse_trig(C, C.asin(v), ctx)
  end,
  acos = function(C, v, ctx)
    return inverse_trig(C, C.acos(v), ctx)
  end,
  atan = function(C, v, ctx)
    return inverse_trig(C, C.atan(v), ctx)
  end,
  -- Calc's own spellings, beside organ's. These answer where Calc
  -- answers, exactly where Calc is exact.
  arcsin = function(C, v, ctx)
    return bounded_inverse(C, "arcsin", C.asin, v, ctx)
  end,
  arccos = function(C, v, ctx)
    return bounded_inverse(C, "arccos", C.acos, v, ctx)
  end,
  arctan = function(C, v, ctx)
    return inverse_on_axis(C, "arctan", v, ctx) or inverse_trig(C, C.atan(v), ctx)
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
    return degree_trig(C, "sin", v)
  end,
  cosd = function(C, v)
    return degree_trig(C, "cos", v)
  end,
  tand = function(C, v)
    return degree_trig(C, "tan", v)
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
    return power(C, a, b)
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
  atan2 = function(C, a, b, ctx)
    return inverse_trig(C, C.atan2(a, b), ctx)
  end,
  arctan2 = function(C, a, b, ctx)
    return inverse_trig(C, C.atan2(a, b), ctx)
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

-- Aggregations that fold with `+` carry a symbol through. (Calc leaves
-- `vproduct` over a symbol unevaluated rather than folding it, so that
-- one stays out.)
local SYMBOLIC_AGG = { vsum = true, vmean = true, vcount = true }

-- `vmax` and `vmin` reduce a symbolic vector to nested `max` / `min`
-- calls; the other orderings have no form organ can spell.
local SYMBOLIC_REDUCE = { vmax = "max", vmin = "min" }

-- Spelled as an operator in a result, so a symbol carries through the
-- operator's own rules rather than leaving the call standing.
local SYMBOLIC_BINARY = { mod = true, pow = true }

-- Calc's spelling for the functions organ takes under another name.
local CALC_NAME = { log = "ln" }

local function any_symbolic(values)
  local C = calc()
  for _, v in ipairs(values) do
    if C.is_symbolic(v) then
      return true
    end
  end
  return false
end

-- Every argument of an aggregation contributes: a reference or a range
-- spreads into the cells it names, anything else stands for itself.
local function collect_arg_values(args, ctx)
  local out = {}
  for _, arg in ipairs(args) do
    local spread
    if arg.kind == "range" or arg.kind == "ref" then
      spread = collect_range_values(arg, ctx)
    else
      local v = eval_calc(arg, ctx)
      if v == nil then
        return nil
      end
      spread = (type(v) == "table" and not v.kind) and v or { v }
    end
    for _, v in ipairs(spread) do
      out[#out + 1] = v
    end
  end
  return out
end

-- `vlen` counts a vector's elements, so a scalar argument has length 0.
local function vector_length(args, ctx)
  if #args > 1 then
    refuse("vlen() over more than one argument")
  end
  local arg = args[1]
  if not arg or arg.kind ~= "range" then
    return calc().from_int(0)
  end
  local values = collect_range_values(arg, ctx)
  if over_fraction(ctx, values) then
    exact_only("vlen", values)
  end
  return calc().from_int(#values)
end

-- Where Calc has no answer for numeric arguments either and keeps the
-- call: a logarithm of zero, a gcd or lcm over a fraction. organ's own
-- functions -- the ones Calc has no name for and always prints back --
-- stand the same way wherever organ has no answer, so a field gets the
-- call rather than an error.
local LOGARITHM = { ln = true, log = true, log10 = true }
local BOUNDED = { asin = true, acos = true }

local function outside_domain(name, values)
  local C = calc()
  if LOGARITHM[name] then
    return C.sign(values[1]) == 0
  end
  if name == "log2" then
    return C.sign(values[1]) <= 0
  end
  if BOUNDED[name] then
    return math.abs(C.to_number(values[1])) > 1
  end
  if name == "binomial" then
    for _, v in ipairs(values) do
      if not C.is_whole(v) then
        return true
      end
    end
    return false
  end
  if name == "factorial" then
    return not C.is_int(values[1]) or C.sign(values[1]) < 0
  end
  if name == "gcd" or name == "lcm" then
    local zeros = 0
    for _, v in ipairs(values) do
      if C.sign(v) == 0 then
        zeros = zeros + 1
      end
    end
    -- A zero argument answers whatever the other one is, whole or not.
    -- `lcm(0, 0)` is the exception: that one is a quotient over zero.
    if zeros > 0 then
      return name == "lcm" and zeros == #values
    end
    for _, v in ipairs(values) do
      if not C.is_whole(v) then
        return true
      end
    end
  end
  return false
end

local function apply_function(name, args, ctx)
  local C = calc()
  if name == "remote" then
    refuse("unsupported function 'remote'")
  end
  -- Conditional: `if(cond, then, else)`. Evaluates only the chosen branch.
  if name == "if" then
    if #args ~= 3 then
      error("formula: if(cond, a, b) needs exactly 3 args")
    end
    local cond = eval_calc(args[1], ctx)
    if cond == nil then
      return nil
    end
    if C.is_symbolic(cond) then
      C.symbolic_refusal("condition in if()")
    end
    local taken = C.is_true(cond) and args[2] or args[3]
    local v = eval_calc(taken, ctx)
    if over_fraction(ctx, { cond, v }) then
      exact_only("if", { cond })
      return v, is_fraction(v)
    end
    return v
  end
  if name == "vlen" then
    return vector_length(args, ctx)
  end
  if AGG[name] then
    local values = collect_arg_values(args, ctx)
    if values == nil then
      return nil
    end
    if over_fraction(ctx, values) then
      if not FRACTION_AGG[name] then
        refuse(name .. "() of a fraction")
      end
      exact_only(name, values)
      return AGG[name](C, values), true
    end
    if not SYMBOLIC_AGG[name] and any_symbolic(values) then
      -- Calc reduces the elements of one vector, and leaves a call over
      -- anything else -- a bare symbol, or a vector plus a scalar.
      local one_vector = #args == 1 and args[1].kind == "range"
      if not (SYMBOLIC_REDUCE[name] and one_vector) then
        C.symbolic_refusal(name .. "()")
      end
      local reduced = values[1]
      for i = 2, #values do
        reduced = C.sym_call(SYMBOLIC_REDUCE[name], { reduced, values[i] })
      end
      return reduced
    end
    local result = AGG[name](C, values)
    if result == nil then
      refuse(name .. "() over an empty vector")
    end
    return result
  end
  if SCALAR_C[name] and #args > 1 and SECOND_ARGUMENT[name] then
    local x = eval_calc(args[1], ctx)
    local n = #args == 2 and eval_calc(args[2], ctx)
    -- Calc rounds an integer to n digits as itself.
    if SECOND_ARGUMENT[name] == "digits" and C.is_int(x) and n and C.is_int(n) then
      return x
    end
    refuse(name .. "() with a second argument")
  end
  if SCALAR_C[name] and #args <= 1 then
    local v = eval_calc(args[1], ctx)
    if v == nil then
      return nil
    end
    if over_fraction(ctx, { v }) then
      if not FRACTION_SCALAR[name] then
        refuse(name .. "() of a fraction")
      end
      exact_only(name, { v })
      return SCALAR_C[name](C, v, ctx), true
    end
    if C.is_symbolic(v) or outside_domain(name, { v }) then
      return C.sym_call(CALC_NAME[name] or name, { v })
    end
    local result = SCALAR_C[name](C, v, ctx)
    if result == nil then
      return C.sym_call(CALC_NAME[name] or name, { v })
    end
    return result
  end
  if BINARY_C[name] then
    local a = eval_calc(args[1], ctx)
    local b = eval_calc(args[2], ctx)
    if a == nil or b == nil then
      return nil
    end
    if over_fraction(ctx, { a, b }) then
      refuse(name .. "() of a fraction")
    end
    if C.is_symbolic(a) or C.is_symbolic(b) then
      if SYMBOLIC_BINARY[name] then
        return BINARY_C[name](C, a, b)
      end
      return C.sym_call(CALC_NAME[name] or name, { a, b })
    end
    if outside_domain(name, { a, b }) then
      return C.sym_call(CALC_NAME[name] or name, { a, b })
    end
    return BINARY_C[name](C, a, b, ctx)
  end
  -- A function Calc has no answer for stays as the call itself, with its
  -- arguments evaluated: `foo($1)` -> `foo(1)`.
  local values = {}
  for i, arg in ipairs(args) do
    local v = eval_calc(arg, ctx)
    if v == nil then
      return nil
    end
    values[i] = v
  end
  if over_fraction(ctx, values) then
    refuse(name .. "() of a fraction")
  end
  return C.sym_call(name, values)
end

local function const_value(name, ctx)
  -- ctx.vars (when present) lets callers inject symbol bindings ahead
  -- of the built-in constants. Used by M.limit / M.integ / any
  -- consumer that wants to evaluate a symbolic expression at a point.
  if ctx and ctx.vars and ctx.vars[name] ~= nil then
    return ctx.vars[name]
  end
  local C = calc()
  -- Calc keeps these symbolic: `pi` is `pi`, `pi*2` is `2 pi`, and
  -- `sin(pi/2)` stands unevaluated. A caller that wants the number
  -- binds it through ctx.vars above.
  if name == "pi" or name == "e" then
    return C.sym(name)
  end
  error("formula: unknown constant '" .. tostring(name) .. "'")
end

-- Internal Calc-typed evaluator. Returns a Calc value or nil for a
-- missing cell (so consumers can short-circuit).
-- (Forward-declared above for apply_function's recursion.)
local function eval_node(node, ctx)
  local C = calc()
  if node.kind == "error" then
    error(node.message)
  end
  if node.kind == "num" then
    if node.float then
      return C.from_float(node.value)
    end
    return C.from_number(node.value)
  end
  if node.kind == "frac" then
    if not ctx then
      return node.value
    end
    ctx.fraction = true
    return node.value, true
  end
  if node.kind == "const" then
    return const_value(node.name, ctx)
  end
  if node.kind == "ref" then
    if node.row_desc == "#" and not node.col_desc then
      return C.from_int(ctx.current_row)
    end
    if node.col_desc == "#" and not node.row_desc then
      return C.from_int(ctx.current_col)
    end
    return cell_value(ctx, resolve_row(node.row_desc, ctx), resolve_col(node.col_desc, ctx))
  end
  if node.kind == "range" then
    return collect_range_values(node, ctx)
  end
  if node.kind == "unop" then
    local a = eval_calc(node.arg, ctx)
    if a == nil then
      return nil
    end
    if over_fraction(ctx, { a }) then
      exact_only("-", { a })
      return C.neg(a), true
    end
    return C.neg(a)
  end
  if node.kind == "binop" then
    local a = eval_calc(node.left, ctx)
    local b = eval_calc(node.right, ctx)
    if a == nil or b == nil then
      return nil
    end
    if over_fraction(ctx, { a, b }) then
      local exact = FRACTION_BINARY[node.op]
      if not exact then
        refuse(node.op .. "() of a fraction")
      end
      exact_only(node.op, { a, b })
      return exact(C, a, b), true
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
      return C.fdiv(a, b)
    end
    if node.op == "%" then
      return C.mod(a, b)
    end
    if node.op == "^" then
      return power(C, a, b)
    end
    error("formula: unknown binop '" .. tostring(node.op) .. "'")
  end
  if node.kind == "cmp" then
    local a = eval_calc(node.left, ctx)
    local b = eval_calc(node.right, ctx)
    if a == nil or b == nil then
      return nil
    end
    if over_fraction(ctx, { a, b }) then
      exact_only(node.op, { a, b })
    elseif C.is_symbolic(a) or C.is_symbolic(b) then
      return C.sym_cmp(node.op, a, b)
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

-- A table formula runs with Calc's Fraction mode off, so an inexact
-- quotient reaches a result as the float it prints as. The exact
-- rationals that survive are Calc's own -- the coefficient of a
-- collected term, and a fraction the formula read or computed in a
-- fraction context (eval_node's second result) -- and those keep its
-- `3:2` spelling.
function eval_calc(node, ctx)
  local v, fraction = eval_node(node, ctx)
  if type(v) == "table" and v.kind == "rat" and not fraction then
    return calc().from_float(calc().to_number(v))
  end
  return v
end

-- Calc's `(float 8)` display with `calc-internal-prec` 12: eight
-- significant digits, scientific notation when the decimal point would
-- sit left of the first digit by two or more places or beyond the
-- twelfth digit, and a trailing "." on integral values.
local function format_float(x)
  if x ~= x or x == math.huge or x == -math.huge then
    return "#ERROR"
  end
  if x < 0 then
    return "-" .. format_float(-x)
  end
  local mant, exp = "0", 0
  if x ~= 0 then
    local digits, e = string.format("%.11e", x):match("^(%d[%.%d]*)e([%+%-]%d+)$")
    digits = digits:gsub("%.", "")
    mant = digits:gsub("0+$", "")
    exp = tonumber(e) - 11 + (#digits - #mant)
    if #mant > 8 then
      local rounded = tonumber(mant:sub(1, 8))
      if tonumber(mant:sub(9, 9)) >= 5 then
        rounded = rounded + 1
      end
      exp = exp + #mant - 8
      mant = tostring(rounded)
    end
  end
  local len = #mant
  local dpos = exp + len
  if dpos >= -1 and dpos <= 12 then
    if dpos == 0 then
      return "0." .. mant
    elseif exp <= 0 and dpos > 0 then
      return mant:sub(1, dpos) .. "." .. mant:sub(dpos + 1)
    elseif exp > 0 then
      return mant .. string.rep("0", exp) .. "."
    end
    return "0." .. string.rep("0", -dpos) .. mant
  end
  local str = len > 1 and (mant:sub(1, 1) .. "." .. mant:sub(2)) or mant
  return str .. "e" .. tostring(dpos - 1)
end

-- Cell text for an evaluation result: a Calc value or a range list.
function M.format_value(v)
  if type(v) ~= "table" then
    return "#ERROR"
  end
  if not v.kind then
    local parts = {}
    for i, item in ipairs(v) do
      parts[i] = M.format_value(item)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  local C = calc()
  if C.is_int(v) then
    return C.to_string(v)
  end
  if C.is_float(v) or v.kind == "rat" then
    return format_float(C.to_number(v))
  end
  if C.is_symbolic(v) then
    return C.render_expr(v, M.format_value)
  end
  local ok, s = pcall(C.to_string, v)
  return ok and s or "#ERROR"
end

-- Emacs reads a result it cannot make a number of the way
-- `string-to-number` does: the number the text starts with, else 0.
local function leading_number(text)
  local n = text:match("^%s*[+-]?%d+%.?%d*[eE][+-]?%d+") or text:match("^%s*[+-]?%d*%.?%d+")
  return tonumber(n) or 0
end

-- Cell text for a result of a fraction context: a fraction spells
-- Calc's `a:b`, inside a vector or an algebraic result too.
local function fraction_text(v)
  if is_fraction(v) then
    return (calc().to_string(v):gsub("/", ":"))
  end
  if type(v) == "table" and not v.kind then
    local parts = {}
    for i, item in ipairs(v) do
      parts[i] = fraction_text(item)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  if calc().is_symbolic(v) then
    return calc().render_expr(v, fraction_text)
  end
  return M.format_value(v)
end

-- A float as Emacs prints it: the shortest digits that read back, and
-- `.0` when nothing marks it a float.
local function float_text(x)
  local text
  for digits = 1, 17 do
    text = string.format("%." .. digits .. "g", x)
    if tonumber(text) == x then
      break
    end
  end
  return text:find("[.en]") and text or text .. ".0"
end

-- printf `fm.fmt` over number `x`, as Emacs's `format` takes it; `float`
-- marks an Emacs float, which `%s` prints as one.
local function printf(fm, x, float)
  if float and fm.conv == "s" then
    x = float_text(x)
  elseif fm.conv:match("[diouxX]") then
    x = x < 0 and -math.floor(-x) or math.floor(x)
  end
  local ok, text = pcall(string.format, fm.fmt, x)
  if not ok then
    return "#ERROR"
  end
  return (text:gsub("^%s+", ""))
end

-- Cell text for a result under a formula's trailing `;` mode. `N` asks
-- for a number, so an algebraic result is an error there; a printf
-- template takes over the rendering entirely. `ctx` is the evaluation's
-- context, when it read a fraction.
function M.format_result(v, fm, ctx)
  if fm and fm.numeric and calc().is_symbolic(v) then
    return "#ERROR"
  end
  local fraction = ctx ~= nil and ctx.fraction == true
  if not (fm and fm.fmt) then
    return fraction and fraction_text(v) or M.format_value(v)
  end
  local x = 0
  if fraction and is_fraction(v) then
    -- Emacs formats the number the result's text starts with, so `1:2`
    -- under `%.2f` is 1.00.
    x = (read_number(fraction_text(v)))
  elseif type(v) == "table" and v.kind then
    local ok, n = pcall(calc().to_number, v)
    x = (ok and tonumber(n)) or leading_number(fraction and fraction_text(v) or M.format_value(v))
  end
  -- Calc has no negative zero, so nothing it prints starts "-0.".
  if x == 0 then
    x = 0
  end
  return printf(fm, x)
end

-- Whether Calc's `num` evaluation takes `v`: a number, or a vector of
-- them.
local function constant(v)
  if type(v) ~= "table" then
    return false
  end
  if not v.kind then
    for _, item in ipairs(v) do
      if not constant(item) then
        return false
      end
    end
    return true
  end
  return calc().is_int(v) or calc().is_float(v) or is_fraction(v)
end

local function two_digits(n)
  local text = require("organ.duration").fixed(n, 0)
  return #text < 2 and "0" .. text or text
end

-- `org-table-time-seconds-to-string` with `format-seconds`'s
-- `%.2h:%.2m:%.2s`: whole units, the fraction of a second dropped.
local function seconds_text(secs, style)
  local a = math.abs(secs)
  local text
  if style == "hours" then
    text = require("organ.duration").fixed(a / 3600, 2)
  else
    local whole = math.floor(a)
    local s = math.fmod(whole, 60)
    local minutes = (whole - s) / 60
    local m = math.fmod(minutes, 60)
    text = two_digits((minutes - m) / 60) .. ":" .. two_digits(m) .. ":" .. two_digits(s)
    if style == "hh:mm" then
      text = text:sub(1, -4)
    end
  end
  return secs < 0 and "-" .. text or text
end

-- Cell text for a formula under `;T`, `;t` or `;U`, evaluated in `ctx`.
-- Emacs signals where Calc's answer is not a number, so organ refuses.
-- The answer's text is read back as seconds: a bare `H:M` or `H:M:S`
-- as hours and minutes (so a fraction `8:75` is 8h 75min), anything
-- else as the number it starts with.
function M.duration_result(fm, ctx)
  local text = fm.literal
  if not text then
    ctx.duration = true
    local ok, v = pcall(eval_calc, fm.expr, ctx)
    if not ok then
      if M.refused(v) then
        error(v, 0)
      end
      refuse("a duration formula Calc cannot read")
    end
    if not constant(v) then
      refuse("a duration formula whose result is not a number")
    end
    text = ctx.fraction and fraction_text(v) or M.format_value(v)
  end
  local secs
  if duration_literal(text) then
    secs = time_seconds(text)
  else
    secs = read_number(text)
  end
  local out = seconds_text(in_range(secs), fm.duration)
  if fm.fmt then
    local x, int = read_number(out)
    return printf(fm, x, not int)
  end
  return out
end

-- Public API. Returns a Lua number for numeric Calc values, the raw
-- list for ranges, or nil for missing cells / division by zero.
-- Backward-compatible with the pre-Calc evaluator.
function M.eval(node, ctx)
  local v = eval_calc(node, ctx)
  if v == nil then
    return nil
  end
  if calc().is_symbolic(v) then
    return v
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
