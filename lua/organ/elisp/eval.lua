-- The evaluator (D5): Emacs's eval_sub, funcall and apply for the
-- subset, with the special forms, the subr.el macros and backquote.el
-- the subset uses, both binding modes and interpreted closures.
--
-- Function values are { k = "fn", kind = ... }: "subr" (a builtin, or an
-- internal function only macro expansions reach) with `def`, "special"
-- (a special form's subr, which funcall reports as invalid) and
-- "closure" { params, body, env }.  `env` is nil for a closure made
-- under dynamic binding; under lexical binding it is a chain of binding
-- cells { sym, val, next } ending in TOP, which stands for Emacs's (t).
--
-- Emacs builds a lexical closure whose environment binds a variable
-- through cconv-make-interpreted-closure, which macroexpands the body
-- once (macroexpand-all), signalling macro errors at creation.  `expand`
-- ports what that does to the subset and refuses `syntax' for any
-- malformed form there; a builtin whose call data says a compiler macro
-- rewrites it refuses `function' there until that rewrite is ported.
--
-- Per call, `run` carries the profile, `env` (nil under dynamic
-- binding), `dyn` (the dynamic binding of each symbol: a cell { v }),
-- `spec` (the binding stack for unwinding) and `globals` (converted
-- ctx.variables).  Only case-fold-search and calendar-date-style may be
-- bound when special; binding another special refuses `special'.

local B = require("organ.elisp.builtins")
local R = require("organ.elisp.run")
local SPECIALS = require("organ.elisp.data.specials")
local V = require("organ.elisp.value")
local convert = require("organ.elisp.convert")
local errors = require("organ.elisp.errors")
local format = require("organ.elisp.format")
local printer = require("organ.elisp.printer")

require("organ.elisp.num")
require("organ.elisp.equal")
require("organ.elisp.list")
require("organ.elisp.sort")

local M = {}

local NIL, T = V.NIL, V.T
local intern = V.intern
local cons = V.cons

local Q_QUOTE = intern("quote")
local Q_FUNCTION = intern("function")
local Q_LAMBDA = intern("lambda")
local Q_OPTIONAL = intern("&optional")
local Q_REST = intern("&rest")
local Q_ERROR = intern("error")
local Q_USER_ERROR = intern("user-error")
local Q_WNA = intern("wrong-number-of-arguments")
local Q_INVALID_FUNCTION = intern("invalid-function")
local Q_VOID_FUNCTION = intern("void-function")
local Q_SETTING_CONSTANT = intern("setting-constant")
local Q_SUCCESS = intern(":success")
local Q_DOCUMENTATION = intern(":documentation")
local Q_INTERACTIVE = intern("interactive")
local Q_DONT_TRIM = intern(":closure-dont-trim-context")
local Q_AUTOLOAD = intern("autoload")
local Q_BACKQUOTE = intern("`")
local Q_COMMA = intern(",")
local Q_COMMA_AT = intern(",@")
local Q_IF = intern("if")
local Q_PROGN = intern("progn")
local Q_PROG1 = intern("prog1")
local Q_LET = intern("let")
local Q_SETQ = intern("setq")
local Q_WHILE = intern("while")
local Q_COND = intern("cond")
local Q_CONDITION_CASE = intern("condition-case")
local Q_FUNCALL = intern("funcall")

local TOP = { top = true }

local CODES = {}
for code in
  ([[syntax function special free-variable setq-global regexp nan unprintable eq-identity
  locale width case-special cycle charset holidays precision profile internal]]):gmatch("%S+")
do
  CODES[code] = true
end

local SPECIAL = {}
for _, name in ipairs(SPECIALS) do
  SPECIAL[name] = true
end

local HONORED = { ["case-fold-search"] = true, ["calendar-date-style"] = true }

local PI = V.float(3.141592653589793)
local FLOAT_E = V.float(2.718281828459045)

local VALUE_KINDS =
  { sym = true, str = true, flt = true, cons = true, vec = true, big = true, fn = true }

local function is_cons(v)
  return type(v) == "table" and v.k == "cons"
end

local function is_sym(v)
  return type(v) == "table" and v.k == "sym"
end

local function is_str(v)
  return type(v) == "table" and v.k == "str"
end

local wta = B.wta

local function wna(head, n)
  R.signal(Q_WNA, V.list({ head, n }))
end

local function invalid_function(x)
  R.signal(Q_INVALID_FUNCTION, V.list({ x }))
end

local function setting_constant(sym)
  R.signal(Q_SETTING_CONSTANT, V.list({ sym }))
end

local function plain_error(text)
  R.signal(Q_ERROR, V.list({ V.str(text) }))
end

-- eval.c's signal_error: (error MSG . ARG), ARG listed unless proper.
local function signal_error(msg, arg)
  local t = arg
  while is_cons(t) do
    t = t.cdr
  end
  if t ~= NIL then
    arg = V.list({ arg })
  end
  R.signal(Q_ERROR, cons(V.str(msg), arg))
end

local function car_of(x)
  if is_cons(x) then
    return x.car
  elseif x == NIL then
    return NIL
  end
  wta("listp", x)
end

local function cdr_of(x)
  if is_cons(x) then
    return x.cdr
  elseif x == NIL then
    return NIL
  end
  wta("listp", x)
end

local function list2(a, b)
  return cons(a, cons(b, NIL))
end

local function list3(a, b, c)
  return cons(a, cons(b, cons(c, NIL)))
end

--- Length of list `x`, charged; a non-nil final cdr signals
--- (wrong-type-argument listp TAIL), as Emacs's list_length.
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

local function proper_length(x)
  local n, t = 0, x
  while is_cons(t) do
    n = n + 1
    t = t.cdr
  end
  return t == NIL and n or nil
end

local function as_value(run, x)
  if type(x) == "table" and VALUE_KINDS[x.k] then
    return x
  end
  return convert.to_value(run, x)
end
M.as_value = as_value

local function check_arity(c, n, through)
  if n < c.min or (c.max and n > c.max) then
    wna(B.head(c, n, through), n)
  end
end

-- Binding

local function cell(sym, val, next_cell)
  return { sym = sym, val = val, next = next_cell }
end

local function lex_cell(run, sym)
  local c, walked = run.env, 0
  while c and c ~= TOP do
    if c.sym == sym then
      run:step(math.floor(walked / 16))
      return c
    end
    c = c.next
    walked = walked + 1
  end
  run:step(math.floor(walked / 16))
end

local function declared_special(sym)
  if sym.uninterned then
    return false
  end
  return sym == NIL or sym == T or V.is_keyword(sym) or SPECIAL[sym.name.s] == true
end

local function specbind(run, sym, val)
  if not is_sym(sym) then
    wta("symbolp", sym)
  end
  if sym == NIL or sym == T then
    setting_constant(sym)
  end
  if V.is_keyword(sym) then
    if val ~= sym then
      setting_constant(sym)
    end
  elseif not sym.uninterned and SPECIAL[sym.name.s] and not HONORED[sym.name.s] then
    R.refuse("special", sym.name.s)
  end
  run:charge(64)
  local spec = run.spec
  local n = spec.n + 2
  spec.n = n
  spec[n - 1] = sym
  spec[n] = run.dyn[sym] or false
  run.dyn[sym] = { v = val }
end

local function unbind_to(run, count)
  local spec = run.spec
  local n = spec.n
  while n > count do
    run.dyn[spec[n - 1]] = spec[n] or nil
    spec[n - 1], spec[n] = nil, nil
    n = n - 2
  end
  spec.n = n
end

local Q_CASE_FOLD = intern("case-fold-search")
local Q_DATE_STYLE = intern("calendar-date-style")

--- case-fold-search as builtins read it: its binding, else ctx.case_fold.
function M.case_fold(run)
  local d = run.dyn and run.dyn[Q_CASE_FOLD]
  if d then
    return d.v ~= NIL
  end
  return run.ctx.case_fold and true or false
end

--- calendar-date-style as builtins read it: its binding, else american.
function M.date_style(run)
  local d = run.dyn and run.dyn[Q_DATE_STYLE]
  return d and d.v or intern("american")
end

local function global_value(run, sym)
  if sym == NIL or sym == T or V.is_keyword(sym) then
    return sym
  end
  if not sym.uninterned then
    local name = sym.name.s
    local vars = run.ctx.variables
    if vars and vars[name] ~= nil then
      local g = run.globals[name]
      if g == nil then
        g = as_value(run, vars[name])
        run.globals[name] = g
      end
      return g
    end
    if name == "case-fold-search" then
      return run.ctx.case_fold and T or NIL
    elseif name == "pi" or name == "float-pi" then
      return PI
    elseif name == "float-e" then
      return FLOAT_E
    end
  end
  R.refuse("free-variable", sym.name.s)
end

local function var_value(run, sym)
  if run.env then
    local c = lex_cell(run, sym)
    if c then
      return c.val
    end
  end
  local d = run.dyn[sym]
  if d then
    return d.v
  end
  return global_value(run, sym)
end

local function set_value(run, sym, val)
  if run.env and is_sym(sym) then
    local c = lex_cell(run, sym)
    if c then
      c.val = val
      return
    end
  end
  if not is_sym(sym) then
    wta("symbolp", sym)
  end
  if sym == NIL or sym == T then
    setting_constant(sym)
  end
  if V.is_keyword(sym) then
    if val == sym then
      return
    end
    setting_constant(sym)
  end
  local d = run.dyn[sym]
  if d then
    d.v = val
    return
  end
  R.refuse("setq-global", sym.name.s)
end

-- Tables filled below

local SPECIAL_FORMS = {}
local MACROS = {}

local function builtin(run, name)
  if not B.SUBSET[name] then
    return nil
  end
  if not B.in_profile(name, run.profile) then
    R.refuse("profile", name)
  end
  local def = B.defs[name]
  if not def then
    R.refuse("function", name)
  end
  return def
end

local function is_macro_name(run, name)
  return MACROS[name] ~= nil or (run.ctx.macros ~= nil and run.ctx.macros[name] ~= nil)
end

-- Evaluation

local eval, funcall, apply_lambda, make_closure, expand, expand_list

local function progn(run, body)
  local val = NIL
  while is_cons(body) do
    val = eval(run, body.car)
    body = body.cdr
  end
  return val
end

local function eval_args(run, args)
  local n = list_length(run, args)
  local argv = { n = n }
  local t = args
  for i = 1, n do
    argv[i] = eval(run, t.car)
    t = t.cdr
  end
  return argv
end

local function form_argv(run, args)
  local n = list_length(run, args)
  local argv = { n = n }
  local t = args
  for i = 1, n do
    argv[i] = t.car
    t = t.cdr
  end
  return argv
end

local hrtime = vim.uv.hrtime

local function signal_value(run, sym, data)
  if sym == NIL and not is_cons(data) then
    sym = Q_ERROR
  end
  local real, rdata, obj = sym, data, nil
  if sym == NIL then
    real, rdata, obj = data.car, data.cdr, data
  end
  if not is_sym(real) then
    wta("symbolp", real)
  end
  local e = not real.uninterned and errors.lookup(real.name.s)
  if not e then
    signal_error("Invalid error symbol", real)
  end
  if e.profiles and not vim.tbl_contains(e.profiles, run.profile) then
    R.refuse("profile", real.name.s)
  end
  if vim.tbl_contains(e.conditions, "quit") then
    R.refuse("function", real.name.s)
  end
  R.signal(real, rdata, obj)
end

local function cx_of(run)
  local cx = run.cx
  if cx then
    return cx
  end
  cx = {
    signal = function(symbol, data)
      if type(symbol) == "string" then
        symbol = intern(symbol)
      end
      signal_value(run, as_value(run, symbol), data == nil and NIL or as_value(run, data))
    end,
    refuse = function(code, detail)
      if not CODES[code] then
        R.refuse("internal", "unknown refusal code " .. tostring(code))
      end
      R.refuse(code, detail)
    end,
    charge = function(steps, bytes)
      run:step(steps or 0)
      run:charge(bytes or 0)
    end,
    eval = function(form)
      local env = run.env
      run.env = run.lexical and TOP or nil
      local v = eval(run, as_value(run, form))
      run.env = env
      return v
    end,
  }
  run.cx = cx
  return cx
end

local function call_consumer(run, spec, argv)
  if type(spec) ~= "table" or type(spec.fn) ~= "function" then
    R.refuse("internal", "consumer spec without fn")
  end
  run:step(1000)
  run:enter()
  local env = run.env
  local t0 = hrtime()
  local v = spec.fn(argv, cx_of(run))
  if spec.timeout then
    run.t0 = run.t0 + (hrtime() - t0)
  end
  run:check_time()
  run.env = env
  run:leave()
  return as_value(run, v)
end

local function call_def(run, def, argv, through)
  check_arity(def, argv.n, through)
  return def.fn(run, argv)
end

local function macroexpand_1(run, mac, args)
  local n = list_length(run, args)
  check_arity(mac.calls, n)
  return mac.fn(run, args, n)
end

local function eval_cons(run, form)
  local head, args = form.car, form.cdr
  if is_sym(head) then
    if head.uninterned then
      R.refuse("function", head.name.s)
    end
    local name = head.name.s
    local sf = SPECIAL_FORMS[name]
    if sf then
      check_arity(sf.calls, list_length(run, args))
      return sf.fn(run, args)
    end
    local mac = MACROS[name]
    if mac then
      return eval(run, macroexpand_1(run, mac, args))
    end
    local ctx = run.ctx
    local spec = ctx.macros and ctx.macros[name]
    if spec then
      return call_consumer(run, spec, form_argv(run, args))
    end
    spec = ctx.functions and ctx.functions[name]
    if spec then
      return call_consumer(run, spec, eval_args(run, args))
    end
    local def = builtin(run, name)
    if def then
      if def.kind == "subr" then
        check_arity(def, list_length(run, args))
        return def.fn(run, eval_args(run, args))
      end
      return call_def(run, def, eval_args(run, args))
    end
    if head == NIL then
      R.signal(Q_VOID_FUNCTION, V.list({ NIL }))
    end
    R.refuse("function", name)
  elseif is_cons(head) then
    local car = head.car
    if car == Q_LAMBDA then
      local fn = make_closure(run, head)
      return apply_lambda(run, fn, eval_args(run, args))
    elseif
      is_sym(car) and (car.name.s == "closure" or car.name.s == "macro" or car == Q_AUTOLOAD)
    then
      R.refuse("function", car.name.s)
    end
  elseif type(head) == "table" and head.k == "fn" then
    if head.kind == "subr" then
      return head.def.fn(run, eval_args(run, args))
    elseif head.kind == "closure" then
      return apply_lambda(run, head, eval_args(run, args))
    end
  end
  invalid_function(head)
end

function eval(run, form)
  run:step(1)
  if type(form) ~= "table" then
    return form
  end
  local k = form.k
  if k == "sym" then
    return var_value(run, form)
  elseif k ~= "cons" then
    return form
  end
  run:enter()
  local v = eval_cons(run, form)
  run:leave()
  return v
end
M.eval = eval

-- funcall_general
function funcall(run, f, argv)
  run:step(1)
  run:enter()
  local v
  if is_sym(f) and f ~= NIL then
    if f.uninterned then
      R.refuse("function", f.name.s)
    end
    local name = f.name.s
    local sf = SPECIAL_FORMS[name]
    if sf then
      invalid_function(sf.calls.obj)
    end
    if is_macro_name(run, name) then
      invalid_function(f)
    end
    local spec = run.ctx.functions and run.ctx.functions[name]
    if spec then
      v = call_consumer(run, spec, argv)
    else
      local def = builtin(run, name)
      if not def then
        R.refuse("function", name)
      end
      v = call_def(run, def, argv, true)
    end
  elseif f == NIL then
    R.signal(Q_VOID_FUNCTION, V.list({ NIL }))
  elseif type(f) == "table" and f.k == "fn" then
    if f.kind == "subr" then
      v = call_def(run, f.def, argv, true)
    elseif f.kind == "closure" then
      v = apply_lambda(run, f, argv)
    else
      invalid_function(f)
    end
  elseif is_cons(f) then
    if f.car == Q_LAMBDA then
      v = apply_lambda(run, f, argv)
    elseif f.car == Q_AUTOLOAD then
      R.refuse("function", "autoload")
    else
      invalid_function(f)
    end
  else
    invalid_function(f)
  end
  run:leave()
  return v
end
M.funcall = funcall

-- funcall_lambda for a closure or a (lambda ...) list
function apply_lambda(run, fn, argv)
  local params, body, lexenv
  if is_cons(fn) then
    local rest = fn.cdr
    if not is_cons(rest) then
      invalid_function(fn)
    end
    params, body, lexenv = rest.car, rest.cdr, nil
  else
    params, body, lexenv = fn.params, fn.body, fn.env
  end
  run:enter()
  local env, count = run.env, run.spec.n
  local n, i = argv.n, 1
  local optional, rest, previous_rest = false, false, false
  local t = params
  while is_cons(t) do
    local nx = t.car
    if not is_sym(nx) then
      invalid_function(fn)
    end
    if nx == Q_REST then
      if rest or previous_rest then
        invalid_function(fn)
      end
      rest, previous_rest = true, true
    elseif nx == Q_OPTIONAL then
      if optional or rest or previous_rest then
        invalid_function(fn)
      end
      optional = true
    else
      local arg
      if rest then
        local count_rest = math.max(0, n - i + 1)
        run:charge(32 * count_rest)
        arg = NIL
        for j = n, i, -1 do
          arg = cons(argv[j], arg)
        end
        i = n + 1
      elseif i <= n then
        arg = argv[i]
        i = i + 1
      elseif not optional then
        wna(fn, n)
      else
        arg = NIL
      end
      if lexenv then
        run:charge(64)
        lexenv = cell(nx, arg, lexenv)
      else
        specbind(run, nx, arg)
      end
      previous_rest = false
    end
    t = t.cdr
  end
  if t ~= NIL or previous_rest then
    invalid_function(fn)
  elseif i <= n then
    wna(fn, n)
  end
  run.env = lexenv
  local v = progn(run, body)
  run.env = env
  unbind_to(run, count)
  run:leave()
  return v
end

-- Lambda lists a closure in an expanded region may have: non-constant
-- symbols, at most one &optional followed by a variable, at most one
-- &rest followed by exactly one final variable.
local function check_params(params)
  local seen_opt, seen_rest, pending, after_rest = false, false, false, 0
  local t = params
  while is_cons(t) do
    local p = t.car
    if p == Q_OPTIONAL then
      if seen_opt or seen_rest then
        return false
      end
      seen_opt, pending = true, true
    elseif p == Q_REST then
      if seen_rest or pending then
        return false
      end
      seen_rest, pending = true, true
    elseif is_sym(p) and p ~= NIL and p ~= T and not V.is_keyword(p) then
      pending = false
      if seen_rest then
        after_rest = after_rest + 1
        if after_rest > 1 then
          return false
        end
      end
    else
      return false
    end
    t = t.cdr
  end
  return t == NIL and not pending
end

-- Ffunction of (lambda . CDR)
function make_closure(run, lam)
  local cdr = lam.cdr
  local params = car_of(cdr)
  local body = cdr_of(cdr)
  if params ~= NIL and not is_cons(params) then
    R.refuse("syntax", "lambda list")
  end
  if is_cons(body) then
    local d = body.car
    if is_str(d) then
      if body.cdr ~= NIL then
        body = body.cdr
      end
    elseif is_cons(d) and d.car == Q_DOCUMENTATION then
      eval(run, car_of(d.cdr))
      body = body.cdr
    end
  end
  local iform
  if is_cons(body) then
    local f = body.car
    if is_cons(f) and f.car == Q_INTERACTIVE then
      iform = f
      body = body.cdr
    end
  end
  if body == NIL then
    body = cons(NIL, NIL)
  end
  if not proper_length(body) then
    R.refuse("syntax", "lambda body")
  end
  local env = run.env
  if env then
    if body.car == Q_DONT_TRIM and body.cdr ~= NIL then
      R.refuse("syntax", ":closure-dont-trim-context")
    end
    if env ~= TOP then
      if iform then
        R.refuse("syntax", "interactive form in a closure")
      end
      if not check_params(params) then
        R.refuse("syntax", "lambda list in a closure")
      end
      body = expand_list(run, body)
    end
  end
  run:charge(64)
  return { k = "fn", kind = "closure", params = params, body = body, env = env }
end

-- Special forms

local function special(name, fn, calls)
  SPECIAL_FORMS[name] = { calls = calls or B.form(name), fn = fn }
end

special("quote", function(_, args)
  return args.car
end)

special("function", function(run, args)
  local f = args.car
  if is_cons(f) and f.car == Q_LAMBDA then
    return make_closure(run, f)
  end
  return f
end)

special("if", function(run, args)
  if eval(run, args.car) ~= NIL then
    return eval(run, args.cdr.car)
  end
  return progn(run, args.cdr.cdr)
end)

special("cond", function(run, args)
  local t = args
  while is_cons(t) do
    local clause = t.car
    local v = eval(run, car_of(clause))
    if v ~= NIL then
      if clause.cdr ~= NIL then
        v = progn(run, clause.cdr)
      end
      return v
    end
    t = t.cdr
  end
  return NIL
end)

special("and", function(run, args)
  local v = T
  while is_cons(args) do
    v = eval(run, args.car)
    if v == NIL then
      break
    end
    args = args.cdr
  end
  return v
end)

special("or", function(run, args)
  local v = NIL
  while is_cons(args) do
    v = eval(run, args.car)
    if v ~= NIL then
      break
    end
    args = args.cdr
  end
  return v
end)

special("progn", progn)

special("prog1", function(run, args)
  local v = eval(run, args.car)
  progn(run, args.cdr)
  return v
end)

special("while", function(run, args)
  local test, body = args.car, args.cdr
  while eval(run, test) ~= NIL do
    run:step(1)
    progn(run, body)
  end
  return NIL
end)

local LET_MSG = "`let' bindings can have only one value-form"

special("let", function(run, args)
  local varlist = args.car
  local nvars = list_length(run, varlist)
  local vals = {}
  local t = varlist
  for i = 1, nvars do
    local elt = t.car
    if is_sym(elt) then
      vals[i] = NIL
    else
      local c = cdr_of(elt)
      if cdr_of(c) ~= NIL then
        signal_error(LET_MSG, elt)
      end
      vals[i] = eval(run, car_of(c))
    end
    t = t.cdr
  end
  local env, count = run.env, run.spec.n
  local lexenv = env
  t = varlist
  for i = 1, nvars do
    local elt = t.car
    local var = is_sym(elt) and elt or car_of(elt)
    if lexenv and is_sym(var) and not declared_special(var) then
      run:charge(64)
      lexenv = cell(var, vals[i], lexenv)
    else
      specbind(run, var, vals[i])
    end
    t = t.cdr
  end
  run.env = lexenv
  local v = progn(run, args.cdr)
  run.env = env
  unbind_to(run, count)
  return v
end)

special("let*", function(run, args)
  local varlist = args.car
  local env, count = run.env, run.spec.n
  local t = varlist
  while is_cons(t) do
    run:step(1)
    local elt = t.car
    local var, val
    if is_sym(elt) then
      var, val = elt, NIL
    else
      var = car_of(elt)
      local c = elt.cdr
      if cdr_of(c) ~= NIL then
        signal_error(LET_MSG, elt)
      end
      val = eval(run, car_of(c))
    end
    if run.env and is_sym(var) and not declared_special(var) then
      run:charge(64)
      run.env = cell(var, val, run.env)
    else
      specbind(run, var, val)
    end
    t = t.cdr
  end
  if t ~= NIL then
    wta("listp", varlist)
  end
  local v = progn(run, args.cdr)
  run.env = env
  unbind_to(run, count)
  return v
end)

special("setq", function(run, args)
  local val = NIL
  local t, nargs = args, 0
  while is_cons(t) do
    local sym = t.car
    t = t.cdr
    if not is_cons(t) then
      wna(Q_SETQ, nargs + 1)
    end
    val = eval(run, t.car)
    t = t.cdr
    set_value(run, sym, val)
    nargs = nargs + 2
  end
  return val
end, { min = 0, obj = { k = "fn", kind = "special", name = "setq" } })

local function condition_matches(cond, conditions)
  if not is_cons(cond) then
    cond = cons(cond, NIL)
  end
  while is_cons(cond) do
    local x = cond.car
    if x == T or (is_sym(x) and not x.uninterned and vim.tbl_contains(conditions, x.name.s)) then
      return true
    end
    cond = cond.cdr
  end
  return false
end

local function run_handler(run, var, val, body)
  if var == NIL then
    return progn(run, body)
  end
  local env, count = run.env, run.spec.n
  if env then
    run:charge(64)
    run.env = cell(var, val, env)
  else
    specbind(run, var, val)
  end
  local v = progn(run, body)
  run.env = env
  unbind_to(run, count)
  return v
end

special("condition-case", function(run, args)
  local var = args.car
  local bodyform = args.cdr.car
  local handlers = args.cdr.cdr
  if not is_sym(var) then
    wta("symbolp", var)
  end
  local success
  local t = handlers
  while is_cons(t) do
    local h = t.car
    if not (h == NIL or (is_cons(h) and (is_sym(h.car) or is_cons(h.car)))) then
      plain_error("Invalid condition handler: " .. printer.princ(run, h))
    end
    if is_cons(h) then
      if h.car == Q_SUCCESS then
        success = h
      elseif is_cons(h.car) and not proper_length(h.car) then
        R.refuse("syntax", "dotted condition list")
      end
    end
    t = t.cdr
  end
  local env, depth, count = run.env, run.depth, run.spec.n
  local ok, val = pcall(eval, run, bodyform)
  if ok then
    if success then
      return run_handler(run, var, val, success.cdr)
    end
    return val
  end
  if type(val) ~= "table" or val.elisp ~= "signal" then
    error(val, 0)
  end
  run.env, run.depth = env, depth
  unbind_to(run, count)
  local conditions = errors.conditions(val.symbol.name.s) or {}
  t = handlers
  while is_cons(t) do
    local h = t.car
    if is_cons(h) and h.car ~= Q_SUCCESS and condition_matches(h.car, conditions) then
      local obj = val.obj or cons(val.symbol, val.data)
      val.obj = obj
      return run_handler(run, var, obj, h.cdr)
    end
    t = t.cdr
  end
  error(val, 0)
end)

-- Builtins

B.define("funcall", function(run, argv)
  local rest = { n = argv.n - 1 }
  for i = 2, argv.n do
    rest[i - 1] = argv[i]
  end
  return funcall(run, argv[1], rest)
end)

B.define("apply", function(run, argv)
  local n = argv.n
  local spread = argv[n]
  local len = list_length(run, spread)
  local all
  if len == 0 then
    all = {}
    for i = 1, math.max(1, n - 1) do
      all[i] = argv[i]
    end
  elseif len == 1 then
    all = {}
    for i = 1, n - 1 do
      all[i] = argv[i]
    end
    all[n] = spread.car
  else
    all = {}
    for i = 1, n - 1 do
      all[i] = argv[i]
    end
    local t = spread
    while is_cons(t) do
      all[#all + 1] = t.car
      t = t.cdr
    end
  end
  local rest = { n = #all - 1 }
  for i = 2, #all do
    rest[i - 1] = all[i]
  end
  return funcall(run, all[1], rest)
end)

B.define("functionp", function(run, argv)
  local x = argv[1]
  if is_sym(x) then
    if x == NIL or x.uninterned then
      return NIL
    end
    local name = x.name.s
    if SPECIAL_FORMS[name] or is_macro_name(run, name) then
      return NIL
    elseif run.ctx.functions and run.ctx.functions[name] then
      return T
    elseif B.SUBSET[name] then
      if not B.in_profile(name, run.profile) then
        R.refuse("profile", name)
      end
      return T
    end
    R.refuse("function", name)
  elseif type(x) == "table" and x.k == "fn" then
    return x.kind == "special" and NIL or T
  end
  return (is_cons(x) and x.car == Q_LAMBDA) and T or NIL
end)

B.define("signal", function(run, argv)
  return signal_value(run, argv[1], argv.n >= 2 and argv[2] or NIL)
end)

B.define("error", function(run, argv)
  R.signal(Q_ERROR, V.list({ format.format(run, argv, true) }))
end)

B.define("user-error", function(run, argv)
  R.signal(Q_USER_ERROR, V.list({ format.format(run, argv, true) }))
end)

-- Internal functions macro expansions call

local function vector_of(run, items, n)
  run:check_list(n)
  run:charge(8 * n)
  local v = { k = "vec", n = n }
  for i = 1, n do
    v[i] = items[i]
  end
  return v
end

local VECTOR = B.internal("vector", function(run, argv)
  return vector_of(run, argv, argv.n)
end)

-- (< COUNTER END) of dotimes: COUNTER is a fixnum.
local LESS = B.internal("<", function(_, argv)
  local a, b = argv[1], argv[2]
  if type(b) == "number" then
    return a < b and T or NIL
  elseif type(b) == "table" and b.k == "flt" then
    return a < b.x and T or NIL
  elseif type(b) == "table" and b.k == "big" then
    return b.n.sign > 0 and T or NIL
  end
  wta("number-or-marker-p", b)
end)

local INC = B.internal("1+", function(_, argv)
  return argv[1] + 1
end)

local APPEND = B.defs.append.obj
local VCONCAT = B.defs.vconcat.obj
local CONS = B.defs.cons.obj
local LIST = B.defs.list.obj
local CAR = B.defs.car.obj
local CDR = B.defs.cdr.obj
local APPLY = B.defs.apply.obj

-- Macros (subr.el)

local function defmacro(name, fn)
  MACROS[name] = { calls = B.form(name), fn = fn }
end

defmacro("when", function(run, args)
  run:charge(96)
  if args.cdr ~= NIL then
    return list3(Q_IF, args.car, cons(Q_PROGN, args.cdr))
  end
  return list3(Q_PROGN, args.car, NIL)
end)

defmacro("unless", function(run, args)
  run:charge(96)
  if args.cdr ~= NIL then
    return cons(Q_IF, cons(args.car, cons(NIL, args.cdr)))
  end
  return list3(Q_PROGN, args.car, NIL)
end)

defmacro("prog2", function(run, args)
  run:charge(160)
  return list3(Q_PROGN, args.car, cons(Q_PROG1, cons(args.cdr.car, args.cdr.cdr)))
end)

defmacro("ignore-errors", function(run, args)
  run:charge(192)
  return cons(Q_CONDITION_CASE, cons(NIL, list2(cons(Q_PROGN, args), list2(Q_ERROR, NIL))))
end)

defmacro("lambda", function(run, args)
  run:charge(64)
  return list2(Q_FUNCTION, cons(Q_LAMBDA, args))
end)

local function copy_list_onto(run, list, tail)
  local items = {}
  local t = list
  while is_cons(t) do
    items[#items + 1] = t.car
    t = t.cdr
  end
  run:charge(32 * #items)
  for i = #items, 1, -1 do
    tail = cons(items[i], tail)
  end
  return tail
end

defmacro("dolist", function(run, args)
  local spec, body = args.car, args.cdr
  if not is_cons(spec) then
    wta("consp", spec)
  end
  local len = list_length(run, spec)
  if len < 2 or len > 3 then
    wna(cons(2, 3), len)
  end
  local tail = V.make_symbol("tail")
  run:charge(512)
  local step = list3(Q_SETQ, tail, list2(CDR, tail))
  local inner = cons(
    Q_LET,
    cons(cons(list2(spec.car, list2(CAR, tail)), NIL), copy_list_onto(run, body, cons(step, NIL)))
  )
  return cons(
    Q_LET,
    cons(cons(list2(tail, spec.cdr.car), NIL), cons(list3(Q_WHILE, tail, inner), spec.cdr.cdr))
  )
end)

defmacro("dotimes", function(run, args)
  local spec, body = args.car, args.cdr
  local var = car_of(spec)
  local count = car_of(cdr_of(spec))
  local ub, counter = V.make_symbol("upper-bound"), V.make_symbol("counter")
  local result = cdr_of(cdr_of(spec))
  run:charge(640)
  local tail = NIL
  if result ~= NIL then
    tail = cons(cons(Q_LET, cons(cons(list2(var, counter), NIL), result)), NIL)
  end
  local loop = cons(
    Q_WHILE,
    cons(
      list3(LESS, counter, ub),
      list2(
        cons(Q_LET, cons(cons(list2(var, counter), NIL), body)),
        list3(Q_SETQ, counter, list2(INC, counter))
      )
    )
  )
  return cons(Q_LET, cons(list2(list2(ub, count), list2(counter, 0)), cons(loop, tail)))
end)

-- backquote.el

local const_eval

local function bq_listify(run, acc, old_tag, old_code)
  local tail, old = old_code, true
  if old_tag == 0 then
    tail = const_eval(run, tail)
    old = false
  end
  local heads = {}
  for i = #acc, 1, -1 do
    local item = acc[i]
    if #heads > 0 or old or item.tag ~= 0 then
      heads[#heads + 1] = item.code
    else
      run:charge(32)
      tail = cons(const_eval(run, item.code), tail)
    end
  end
  run:charge(64 * (#heads + 1))
  if tail ~= NIL then
    if not old then
      tail = list2(Q_QUOTE, tail)
    end
    for j = 1, #heads do
      tail = list3(CONS, heads[j], tail)
    end
    return tail
  end
  local out = NIL
  for j = 1, #heads do
    out = cons(heads[j], out)
  end
  return cons(LIST, out)
end

local bq_process

local function bq_nth1(s)
  return car_of(cdr_of(s))
end

local function bq_delay(run, s, level)
  local tag, code = bq_process(run, s.cdr, level)
  local exp = bq_listify(run, { { tag = 0, code = list2(Q_QUOTE, s.car) } }, tag, code)
  return (is_cons(exp) and exp.car == Q_QUOTE) and 0 or 1, exp
end

local function multiple_args(run, what, s)
  plain_error("Multiple args to " .. what .. " are not supported: " .. printer.prin1(run, s, false))
end

-- backquote-process: the tag (0 constant, 1 computed, 2 spliced) and
-- the code of S.
function bq_process(run, s, level)
  run:step(1)
  if type(s) == "table" and s.k == "vec" then
    local tag, code = bq_process(run, V.list(s, s.n), level)
    if tag == 0 then
      return 0, s
    end
    run:charge(96)
    if not (code == NIL or is_cons(code)) then
      return 1, list2(VCONCAT, code)
    elseif car_of(code) == LIST then
      return 1, cons(VECTOR, code.cdr)
    elseif car_of(code) == APPEND then
      return 1, cons(VCONCAT, code.cdr)
    end
    return 1, list3(APPLY, VECTOR, code)
  end
  if not is_cons(s) then
    if s == NIL or s == T or not is_sym(s) then
      return 0, s
    end
    run:charge(64)
    return 0, list2(Q_QUOTE, s)
  end
  local head = s.car
  if head == Q_COMMA then
    if level > 0 then
      return bq_delay(run, s, level - 1)
    end
    if list_length(run, s) > 2 then
      multiple_args(run, ",", s)
    end
    local x = bq_nth1(s)
    return (is_cons(x) and x.car == Q_QUOTE) and 0 or 1, x
  elseif head == Q_COMMA_AT then
    if level > 0 then
      return bq_delay(run, s, level - 1)
    end
    if list_length(run, s) > 2 then
      multiple_args(run, ",@", s)
    end
    return 2, bq_nth1(s)
  elseif head == Q_BACKQUOTE then
    return bq_delay(run, s, level + 1)
  end
  run:enter()
  local rest = s
  local firstlist, acc, lists = nil, {}, {}
  while is_cons(rest) and rest.car ~= Q_COMMA and rest.car ~= Q_BACKQUOTE do
    local tag, code = bq_process(run, rest.car, level)
    if tag == 2 then
      if #lists == 0 then
        firstlist, acc = acc, {}
      end
      if #acc > 0 then
        lists[#lists + 1] = bq_listify(run, acc, 0, NIL)
      end
      lists[#lists + 1] = code
      acc = {}
    else
      acc[#acc + 1] = { tag = tag, code = code }
    end
    rest = rest.cdr
  end
  if rest ~= NIL or #acc > 0 then
    local tag, code = bq_process(run, rest, level)
    lists[#lists + 1] = bq_listify(run, acc, tag, code)
  end
  local expression = lists[#lists]
  if #lists > 1 or (is_cons(expression) and expression.car == Q_COMMA_AT) then
    run:charge(32 * (#lists + 1))
    expression = cons(APPEND, V.list(lists, #lists))
  end
  if firstlist and #firstlist > 0 then
    expression = bq_listify(run, firstlist, 1, expression)
  end
  run:leave()
  return (is_cons(expression) and expression.car == Q_QUOTE) and 0 or 1, expression
end

function const_eval(run, code)
  local env = run.env
  run.env = nil
  local v = eval(run, code)
  run.env = env
  return v
end

local function backquote(run, args)
  local _, code = bq_process(run, args.car, 0)
  return code
end

defmacro("`", backquote)
defmacro("backquote", backquote)

-- macroexpand-all, as cconv-make-interpreted-closure applies it

local function nonconst_sym(x)
  return is_sym(x) and x ~= NIL and x ~= T and not V.is_keyword(x)
end

local function malformed(what)
  R.refuse("syntax", what .. " in a closure")
end

function expand_list(run, forms)
  local items, n = {}, 0
  local t = forms
  while is_cons(t) do
    n = n + 1
    items[n] = expand(run, t.car)
    t = t.cdr
  end
  if t ~= NIL then
    malformed("dotted form")
  end
  run:charge(32 * n)
  return V.list(items, n)
end

local function expand_lambda(run, lam)
  local rest = lam.cdr
  if not is_cons(rest) or not check_params(rest.car) then
    malformed("lambda list")
  end
  local body = rest.cdr
  if not proper_length(body) then
    malformed("lambda body")
  end
  local first = body.car
  if is_cons(first) and (first.car == Q_DOCUMENTATION or first.car == Q_INTERACTIVE) then
    malformed("lambda declaration")
  end
  if is_cons(body) and is_cons(body.cdr) then
    local second = body.cdr.car
    if is_str(first) and is_cons(second) and second.car == Q_INTERACTIVE then
      malformed("lambda declaration")
    end
  end
  if first == Q_DONT_TRIM then
    malformed(":closure-dont-trim-context")
  end
  return cons(Q_LAMBDA, cons(rest.car, expand_list(run, body)))
end

local function param_counts(params)
  local required, max, optional = 0, 0, false
  local t = params
  while is_cons(t) do
    local p = t.car
    if p == Q_OPTIONAL then
      optional = true
    elseif p == Q_REST then
      return required, nil
    else
      max = max + 1
      if not optional then
        required = required + 1
      end
    end
    t = t.cdr
  end
  return required, max
end

-- macroexp--unfold-lambda of (funcall (function LAM) . EARGS)
local function unfold(run, eexp, eargs, form)
  local lam = eexp.cdr.car
  local params = lam.cdr.car
  local body = lam.cdr.cdr
  while is_cons(body) and is_str(body.car) and body.cdr ~= NIL do
    body = body.cdr
  end
  local actuals = {}
  local t = eargs
  while is_cons(t) do
    actuals[#actuals + 1] = t.car
    t = t.cdr
  end
  local required, max = param_counts(params)
  if #actuals < required or (max and #actuals > max) then
    return form
  end
  local bindings, a, restp = {}, 1, false
  t = params
  while is_cons(t) do
    local p = t.car
    if declared_special(p) then
      return form
    end
    if p == Q_REST then
      restp = true
    elseif p ~= Q_OPTIONAL and restp then
      local rest = NIL
      for k = #actuals, a, -1 do
        rest = cons(actuals[k], rest)
      end
      bindings[#bindings + 1] = list2(p, a <= #actuals and cons(LIST, rest) or NIL)
      a = #actuals + 1
    elseif p ~= Q_OPTIONAL then
      bindings[#bindings + 1] = list2(p, actuals[a] or NIL)
      a = a + 1
    end
    t = t.cdr
  end
  run:charge(64 * (#bindings + 1))
  if #bindings > 0 then
    return cons(Q_LET, cons(V.list(bindings), body))
  elseif is_cons(body) and body.cdr ~= NIL then
    return cons(Q_PROGN, body)
  end
  return car_of(body)
end

-- Compiler macros macroexpand-all applies: the rewritten form, or nil
-- when the macro leaves the call as it is (its arity check failed).
local Q_NUM_EQ = intern("=")

local Q_STRING_LESSP = intern("string-lessp")

local function string_greaterp(args, n)
  if n == 2 then
    local arg1 = V.make_symbol("arg1")
    return list3(
      Q_LET,
      V.list({ list2(arg1, args.car) }),
      list3(Q_STRING_LESSP, args.cdr.car, arg1)
    )
  end
end

local Q_CAR = intern("car")
local Q_CDR = intern("cdr")

-- internal--compiler-macro-cXXr: (cXYr X) is (cXr (cYr X)).
local function cxxr(outer, inner)
  return function(args, n)
    if n == 1 then
      return list2(outer, list2(inner, args.car))
    end
  end
end

local COMPILER_MACROS = {
  zerop = function(args, n)
    if n == 1 then
      return list3(Q_NUM_EQ, 0, args.car)
    end
  end,
  ["string>"] = string_greaterp,
  ["string-greaterp"] = string_greaterp,
  caar = cxxr(Q_CAR, Q_CAR),
  cadr = cxxr(Q_CAR, Q_CDR),
  cdar = cxxr(Q_CDR, Q_CAR),
  cddr = cxxr(Q_CDR, Q_CDR),
}

local function expand_form(run, form)
  local h, args = form.car, form.cdr
  local n = proper_length(args)
  if not n then
    malformed("dotted form")
  end
  if type(h) == "table" and h.k == "fn" and h.kind == "subr" then
    return cons(h, expand_list(run, args))
  elseif not is_sym(h) or h.uninterned then
    malformed((is_cons(h) and h.car == Q_LAMBDA) and "lambda call" or "call")
  end
  local name = h.name.s
  if name == "quote" then
    if n ~= 1 then
      malformed("quote")
    end
    return form
  elseif name == "function" then
    if n ~= 1 then
      malformed("function")
    end
    local f = args.car
    if is_cons(f) and f.car == Q_LAMBDA then
      return list2(Q_FUNCTION, expand_lambda(run, f))
    end
    return form
  elseif name == "cond" then
    local clauses = {}
    local t = args
    while is_cons(t) do
      if t.car ~= NIL and not (is_cons(t.car) and proper_length(t.car)) then
        malformed("cond clause")
      end
      clauses[#clauses + 1] = expand_list(run, t.car)
      t = t.cdr
    end
    return cons(Q_COND, V.list(clauses))
  elseif name == "condition-case" then
    if n < 2 or not (args.car == NIL or nonconst_sym(args.car)) then
      malformed("condition-case")
    end
    local body = expand(run, args.cdr.car)
    if args.cdr.cdr == NIL then
      return body
    end
    local hs = {}
    local t = args.cdr.cdr
    while is_cons(t) do
      local hd = t.car
      if not (is_cons(hd) and proper_length(hd)) then
        malformed("condition handler")
      end
      local c = hd.car
      if is_cons(c) then
        local ct = c
        while is_cons(ct) do
          if not is_sym(ct.car) then
            malformed("condition list")
          end
          ct = ct.cdr
        end
        if ct ~= NIL then
          malformed("condition list")
        end
      elseif not is_sym(c) then
        malformed("condition handler")
      end
      hs[#hs + 1] = cons(c, expand_list(run, hd.cdr))
      t = t.cdr
    end
    return cons(Q_CONDITION_CASE, cons(args.car, cons(body, V.list(hs))))
  elseif name == "let" or name == "let*" then
    if n < 1 or not proper_length(args.car) then
      malformed(name)
    end
    local bs = {}
    local t = args.car
    while is_cons(t) do
      local b = t.car
      if nonconst_sym(b) then
        bs[#bs + 1] = b
      else
        local len = is_cons(b) and proper_length(b)
        if not len or len > 2 or not nonconst_sym(b.car) then
          malformed(name .. " binding")
        end
        bs[#bs + 1] = cons(b.car, expand_list(run, b.cdr))
      end
      t = t.cdr
    end
    return cons(h, cons(V.list(bs), expand_list(run, args.cdr)))
  elseif name == "setq" then
    if n % 2 == 1 then
      malformed("setq")
    end
    local items = {}
    local t = args
    while is_cons(t) do
      if not nonconst_sym(t.car) then
        malformed("setq")
      end
      items[#items + 1] = t.car
      items[#items + 1] = expand(run, t.cdr.car)
      t = t.cdr.cdr
    end
    return cons(h, V.list(items))
  elseif name == "if" or name == "prog1" or name == "while" then
    if n < (name == "if" and 2 or 1) then
      malformed(name)
    end
    return cons(h, expand_list(run, args))
  elseif name == "and" or name == "or" or name == "progn" then
    return cons(h, expand_list(run, args))
  elseif name == "funcall" then
    if n == 0 then
      return form
    end
    local eexp = expand(run, args.car)
    local eargs = expand_list(run, args.cdr)
    if is_cons(eexp) and eexp.car == Q_FUNCTION then
      local f = eexp.cdr.car
      if is_sym(f) and not SPECIAL_FORMS[f.name.s] and not is_macro_name(run, f.name.s) then
        return expand(run, cons(f, eargs))
      elseif is_cons(f) and f.car == Q_LAMBDA then
        return unfold(run, eexp, eargs, cons(Q_FUNCALL, cons(eexp, eargs)))
      end
    end
    return cons(Q_FUNCALL, cons(eexp, eargs))
  end
  local ctx = run.ctx
  if ctx.functions and ctx.functions[name] then
    return cons(h, expand_list(run, args))
  end
  local def = builtin(run, name)
  if not def then
    R.refuse("function", name)
  end
  if def.compiler_macro then
    local cm = COMPILER_MACROS[name]
    if not cm then
      R.refuse("function", name)
    end
    local rewritten = cm(args, n)
    if rewritten then
      return expand(run, rewritten)
    end
  end
  return cons(h, expand_list(run, args))
end

function expand(run, form)
  run:step(1)
  if not is_cons(form) then
    return form
  end
  run:enter()
  while is_cons(form) do
    local h = form.car
    if not is_sym(h) or h.uninterned then
      break
    end
    local mac = MACROS[h.name.s]
    if not mac then
      if run.ctx.macros and run.ctx.macros[h.name.s] then
        R.refuse("function", h.name.s)
      end
      break
    end
    if not proper_length(form.cdr) then
      malformed("dotted form")
    end
    form = macroexpand_1(run, mac, form.cdr)
  end
  local out = is_cons(form) and expand_form(run, form) or form
  run:leave()
  return out
end

-- Entry

--- Prepare `run` for evaluation under its ctx's profile.
function M.setup(run)
  if run.spec then
    return
  end
  local ctx = run.ctx
  local profile = ctx.profile or "table"
  local lexical = B.PROFILES[profile]
  if lexical == nil then
    R.refuse("internal", "unknown profile " .. tostring(profile))
  end
  run.profile = profile
  run.lexical = lexical
  run.env = lexical and TOP or nil
  run.dyn = {}
  run.spec = { n = 0 }
  run.globals = {}
end

--- Evaluate `form` as the profile's Emacs entry point does.
function M.eval_top(run, form)
  M.setup(run)
  return eval(run, as_value(run, form))
end

--- Call builtin `name` of the profile with `args`, as a direct call.
function M.call(run, name, args)
  M.setup(run)
  if type(name) ~= "string" or type(args) ~= "table" then
    R.refuse("internal", "call: name and args")
  end
  local def = builtin(run, name)
  if not def then
    R.refuse("function", name)
  end
  local argv = { n = #args }
  for i = 1, argv.n do
    argv[i] = as_value(run, args[i])
  end
  return call_def(run, def, argv)
end

return M
