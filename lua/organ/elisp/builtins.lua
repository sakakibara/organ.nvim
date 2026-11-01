-- The builtin function subset (D5a), which builtins each profile has
-- (D5b), and the generated call data of the special forms, macros and
-- builtins the evaluator implements (data/functions.lua).
--
-- A builtin is `def = { name, kind, min, max, head, heads,
-- funcall_head, funcall_heads, fn, obj }`: `kind` "subr" checks its
-- argument count before its arguments are evaluated and "lisp" after,
-- as Emacs; `fn(run, argv)` receives an array with `argv.n` evaluated
-- arguments; `obj` is its function value, the subr Emacs puts in data
-- signalled through `funcall'.

local DATA = require("organ.elisp.data.functions")
local R = require("organ.elisp.run")
local V = require("organ.elisp.value")

local M = {}

local NIL = V.NIL

local function set_of(text)
  local s = {}
  for name in text:gmatch("%S+") do
    s[name] = true
  end
  return s
end

M.SUBSET = set_of([[
  + - * / % mod 1+ 1- abs max min floor ceiling round truncate float ffloor
  fceiling fround ftruncate expt sqrt exp log sin cos tan asin acos atan isnan
  logand logior logxor lognot ash = /= < > <= >= zerop natnump numberp integerp
  floatp number-to-string string-to-number
  null not atom consp listp nlistp stringp symbolp vectorp sequencep functionp
  booleanp characterp keywordp eq eql equal identity ignore
  concat substring string-to-char char-to-string string make-string
  string-to-list string-to-vector length string= string-equal string<
  string-lessp string> string-greaterp string-prefix-p string-suffix-p
  string-search string-replace string-empty-p string-blank-p upcase downcase
  capitalize upcase-initials string-trim string-trim-left string-trim-right
  split-string string-join mapconcat format symbol-name intern string-width
  truncate-string-to-width string-pad
  list cons car cdr car-safe cdr-safe caar cadr cdar cddr nth nthcdr last
  butlast append vconcat nconc reverse nreverse member memq memql assoc assq
  rassoc rassq alist-get number-sequence mapcar mapc mapcan remove remq delete
  delq delete-dups sort aref elt seq-filter seq-remove seq-map seq-reduce
  seq-take seq-drop seq-uniq seq-contains-p seq-elt seq-first seq-rest
  seq-position
  apply funcall error signal user-error
  current-time float-time format-time-string encode-time decode-time time-add
  time-subtract time-less-p time-equal-p org-time-string-to-time
  org-time-stamp-format
  calendar-day-of-week calendar-absolute-from-gregorian
  calendar-gregorian-from-absolute calendar-extract-month calendar-extract-day
  calendar-extract-year calendar-leap-year-p calendar-last-day-of-month
  calendar-day-number calendar-date-is-valid-p
  diary-date diary-block diary-cyclic diary-anniversary diary-float org-date
  org-block org-cyclic org-anniversary org-class
  org-lookup-first org-lookup-last org-lookup-all
]])

local DIARY = set_of([[
  diary-date diary-block diary-cyclic diary-anniversary diary-float org-date
  org-block org-cyclic org-anniversary org-class
]])

local PREFIX = set_of("org-date org-block org-cyclic org-anniversary org-class")

--- Profiles and whether each binds lexically.
M.PROFILES = {
  table = false,
  diary = false,
  link = false,
  prefix = true,
  capture = true,
  var = true,
}

--- Whether builtin `name` of the subset exists in `profile`.
function M.in_profile(name, profile)
  if not DIARY[name] then
    return true
  end
  return profile == "diary" or (profile == "prefix" and PREFIX[name] == true)
end

local function decode(x, obj)
  if type(x) == "number" then
    return x
  elseif x.subr then
    return obj
  elseif x.sym then
    return V.intern(x.sym)
  end
  return V.cons(decode(x.car, obj), decode(x.cdr, obj))
end

--- Call data of a special form, macro or builtin: { kind, min, max,
--- holes, head, heads, funcall_head, funcall_heads } with heads as
--- values (`heads`: per argument count where it differs; `holes`: the
--- counts between min and max it refuses), `obj` its function value.
local calls = {}

function M.calls(name)
  return calls[name]
end

local function decode_heads(t, obj)
  if not t then
    return nil
  end
  local out = {}
  for n, h in pairs(t) do
    out[n] = decode(h, obj)
  end
  return out
end

local function call_data(name, obj)
  local d = DATA[name]
  if not d then
    error("organ.elisp: no call data for " .. name)
  end
  local c = {
    name = name,
    kind = d.kind,
    min = d.min,
    max = d.max,
    head = d.head and decode(d.head, obj),
    heads = decode_heads(d.heads, obj),
    funcall_head = d.funcall_head and decode(d.funcall_head, obj),
    funcall_heads = decode_heads(d.funcall_heads, obj),
    compiler_macro = d.compiler_macro,
    holes = d.holes,
    obj = obj,
  }
  calls[name] = c
  return c
end

--- The head of the (wrong-number-of-arguments HEAD N) data call data `c`
--- signals for `n` arguments, called directly or `through` funcall.
function M.head(c, n, through)
  if through and c.funcall_head then
    return c.funcall_heads and c.funcall_heads[n] or c.funcall_head
  end
  return c.heads and c.heads[n] or c.head
end

M.defs = {}

--- Define builtin `name` of the subset with `fn(run, argv)`.
function M.define(name, fn)
  assert(M.SUBSET[name], name)
  local obj = { k = "fn", kind = "subr", name = name }
  local def = call_data(name, obj)
  def.fn = fn
  obj.def = def
  M.defs[name] = def
  return def
end

--- Call data of special form or macro `name`; a special form's value
--- is its subr, which `funcall' reports as invalid.
function M.form(name)
  local d = DATA[name]
  local obj = d and d.kind == "special" and { k = "fn", kind = "special", name = name } or nil
  return call_data(name, obj)
end

--- An internal function value for the forms macros expand to; it is
--- reached only from those expansions, never by name.
function M.internal(name, fn)
  local obj = { k = "fn", kind = "subr", name = name }
  obj.def = { name = name, kind = "subr", min = 0, fn = fn, obj = obj }
  return obj
end

local function wta(pred, x)
  R.signal(V.intern("wrong-type-argument"), V.list({ V.intern(pred), x }))
end
M.wta = wta

M.define("identity", function(_, argv)
  return argv[1]
end)

M.define("ignore", function()
  return NIL
end)

local function kind(v)
  local t = type(v)
  if t == "number" then
    return "int"
  end
  return v.k
end

local function predicate(name, test)
  M.define(name, function(_, argv)
    return test(argv[1]) and V.T or NIL
  end)
end

local function is_list(v)
  return v == NIL or kind(v) == "cons"
end

predicate("null", function(x)
  return x == NIL
end)
predicate("not", function(x)
  return x == NIL
end)
predicate("atom", function(x)
  return kind(x) ~= "cons"
end)
predicate("consp", function(x)
  return kind(x) == "cons"
end)
predicate("listp", is_list)
predicate("nlistp", function(x)
  return not is_list(x)
end)
predicate("stringp", function(x)
  return kind(x) == "str"
end)
predicate("symbolp", function(x)
  return kind(x) == "sym"
end)
predicate("vectorp", function(x)
  return kind(x) == "vec"
end)
predicate("sequencep", function(x)
  local k = kind(x)
  return k == "cons" or k == "vec" or k == "str" or x == NIL
end)
predicate("booleanp", function(x)
  return x == NIL or x == V.T
end)
predicate("characterp", function(x)
  return type(x) == "number" and x >= 0 and x <= 0x3FFFFF
end)
predicate("keywordp", function(x)
  return V.is_keyword(x)
end)

M.define("cons", function(run, argv)
  run:charge(32)
  return V.cons(argv[1], argv[2])
end)

M.define("list", function(run, argv)
  run:check_list(argv.n)
  run:step(argv.n)
  run:charge(32 * argv.n)
  return V.list(argv, argv.n)
end)

M.define("car", function(_, argv)
  local x = argv[1]
  if x == NIL then
    return NIL
  elseif type(x) == "table" and x.k == "cons" then
    return x.car
  end
  wta("listp", x)
end)

M.define("cdr", function(_, argv)
  local x = argv[1]
  if x == NIL then
    return NIL
  elseif type(x) == "table" and x.k == "cons" then
    return x.cdr
  end
  wta("listp", x)
end)

return M
