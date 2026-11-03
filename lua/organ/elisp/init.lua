-- A bounded Emacs Lisp reader, printer and evaluator for the
-- side-effect-free subset org files use.  Internal.
--
-- Every entry point returns one result and never raises:
--   { ok = true, value = v }              (read adds next_pos)
--   { ok = false, kind = "signal", symbol = <name>, data = <list>, text }
--   { ok = false, kind = "refused", code = <code>, detail = <string> }
--   { ok = false, kind = "limit", cap = <cap> }
-- `text` is (format "%s" err), or nil when the data holds a value organ
-- does not print.  Each call runs in a fresh coroutine under the caps of
-- organ.elisp.run, lowered by `ctx.caps` and shared through
-- `ctx.budget` (which accumulates `steps`, `alloc` and `time` in ms).
-- An entry point a consumer function calls while a call runs is nested
-- in that call: it gets no more than the call's remaining caps and
-- depth, and a limit it hits ends the call too.  A malformed ctx, value
-- or consumer result, or a consumer function that yields, gives
-- `refused internal`.
-- `ctx.escape_newlines` is print-escape-newlines for printing.
--
-- Evaluation reads, all optional:
--   ctx.profile    "table" (default), "diary", "link" (dynamic binding),
--                  "prefix", "capture", "var" (lexical binding)
--   ctx.case_fold  case-fold-search
--   ctx.syntax_table  "org" (default) or "agenda": the syntax table of the
--                  buffer current in Emacs, for the builtins that find words
--   ctx.variables  { name = value }: global dynamic values (not special)
--   ctx.functions  { name = spec }: spec.fn(argv, cx) gets the evaluated
--                  arguments (argv[1..argv.n]) and returns a value
--   ctx.macros     { name = spec }: as functions, with argument forms
-- Each consumer call is charged at least 1 000 steps and its wall time
-- counts unless spec.timeout is set.  `cx` offers signal(symbol, data)
-- (symbol a name or a symbol value), refuse(code, detail),
-- charge(steps, bytes) and eval(form), which shares the call's caps,
-- budget, depth and dynamic bindings.  Values given as Lua data convert
-- as to_value does.

local R = require("organ.elisp.run")
local V = require("organ.elisp.value")
local convert = require("organ.elisp.convert")
local errors = require("organ.elisp.errors")
local evaluator = require("organ.elisp.eval")
local printer = require("organ.elisp.printer")
local reader = require("organ.elisp.reader")
local subst = require("organ.elisp.subst")
local syntax = require("organ.elisp.syntax")

local M = {}

M.NIL = V.NIL
M.T = V.T

local function internal(detail)
  return { ok = false, kind = "refused", code = "internal", detail = detail }
end

-- `text` is printed under the call's own run, so its caps and budget
-- pay for it, and a cap hit while printing it is that limit.  It is nil
-- when the data holds a value organ does not print or Emacs's printer
-- signals on.
local function signal_result(run, e)
  local name = e.symbol.name.s
  local ok, text = false, nil
  if run then
    run.depth = run.depth0
    ok, text = pcall(printer.princ, run, V.cons(e.symbol, e.data), true)
    if not ok then
      local kind = type(text) == "table" and text.elisp
      if kind == "limit" then
        return { ok = false, kind = "limit", cap = text.cap }
      elseif not (kind == "signal" or (kind == "refused" and text.code ~= "internal")) then
        return internal(kind and tostring(text.detail) or tostring(text))
      end
    end
  end
  return {
    ok = false,
    kind = "signal",
    symbol = name,
    data = e.data,
    text = ok and text or nil,
  }
end

local function result_of(run, e)
  if not errors.valid(e) then
    if type(e) == "table" and e.elisp then
      return internal(
        ("invalid %s: %s"):format(tostring(e.elisp), tostring(e.code or e.cap or e.symbol))
      )
    end
    return internal(tostring(e))
  elseif e.elisp == "signal" then
    return signal_result(run, e)
  elseif e.elisp == "refused" then
    return { ok = false, kind = "refused", code = e.code, detail = e.detail }
  end
  return { ok = false, kind = "limit", cap = e.cap }
end

-- Run fn(run, ...) in a fresh coroutine and turn its outcome into a
-- result; fn returns the result's value (and next_pos for read).  An
-- entry reached while another call runs (from a consumer function) is
-- nested in it: it shares that call's caps, budget and depth.
local function entry(ctx, fn, ...)
  local args = { n = select("#", ...), ... }
  local parent = R.active
  local run
  local co = coroutine.create(function()
    return pcall(function()
      run = R.new(ctx, parent)
      R.active = run
      local ok, value, next_pos = pcall(function()
        if parent then
          run:enter()
        end
        return fn(run, unpack(args, 1, args.n))
      end)
      if not ok then
        return result_of(run, value)
      end
      return { ok = true, value = value, next_pos = next_pos }
    end)
  end)
  local resumed, ok, res = coroutine.resume(co)
  R.active = parent
  if coroutine.status(co) ~= "dead" then
    res = internal("a consumer function yielded")
  elseif not (resumed and ok) then
    res = result_of(nil, resumed and res or ok)
  end
  if run then
    run:settle(res.kind == "limit" and res.cap)
  end
  return res
end

-- Byte position `pos` (default 1) of source text `src`.
local function position(src, pos)
  pos = pos or 1
  if
    type(src) ~= "string"
    or type(pos) ~= "number"
    or pos % 1 ~= 0
    or pos < 1
    or pos > #src + 1
  then
    R.refuse("internal", "source text and position")
  end
  return pos
end

local function ctx_of(ctx)
  return ctx or {}
end

--- One form from byte `pos` (default 1) of `src`, skipping whitespace
--- and comments; `next_pos` is the byte after it.
function M.read(src, pos, ctx)
  return entry(ctx, function(run)
    return reader.read(run, src, position(src, pos))
  end)
end

--- `scan-sexps` from byte `pos` by one expression under the "org" or
--- "elisp" syntax table: the byte after it, or nil when none follows.
function M.scan_sexp(src, pos, syntax_name)
  return entry(nil, function(run)
    local e = syntax.scan_sexp(run, src, position(src, pos), syntax_name)
    return e or V.NIL
  end)
end

--- Evaluate `form` (a value) under `ctx`.
function M.eval(form, ctx)
  return entry(ctx, function(run)
    return evaluator.eval_top(run, form)
  end)
end

--- `read` at byte 1, then `eval`; trailing text is ignored.
function M.eval_string(src, ctx)
  return entry(ctx, function(run)
    return evaluator.eval_top(run, (reader.read(run, src, 1)), src)
  end)
end

--- Call builtin `name` of the profile with the array `args`.
function M.call(name, args, ctx)
  return entry(ctx, function(run)
    return evaluator.call(run, name, args)
  end)
end

--- org-capture--expand-keyword-in-embedded-elisp: `form` with each
--- symbol whose name holds "%:KEY" replaced by the value `plist` maps
--- the keyword name ":KEY" to, when that is non-nil.
function M.subst_symbols(form, plist, ctx)
  return entry(ctx, function(run)
    return subst.subst_symbols(run, form, plist)
  end)
end

function M.prin1(value, ctx)
  return entry(ctx, function(run)
    return printer.prin1(run, value, ctx_of(ctx).escape_newlines)
  end)
end

function M.princ(value, ctx)
  return entry(ctx, function(run)
    return printer.princ(run, value)
  end)
end

--- The length in characters of (format "%S" form).
function M.printed_length(form, ctx)
  return entry(ctx, function(run)
    return V.utf8_len(printer.prin1(run, form, ctx_of(ctx).escape_newlines))
  end)
end

--- error-message-string of a signal result.
function M.error_message(result, ctx)
  return entry(ctx, function(run)
    if type(result) ~= "table" or result.kind ~= "signal" then
      R.refuse("internal", "error_message of a non-signal result")
    end
    return errors.message(run, result.symbol, result.data, ctx_of(ctx).escape_newlines)
  end)
end

function M.to_value(x, ctx)
  return entry(ctx, function(run)
    return convert.to_value(run, x)
  end)
end

function M.to_lua(v, ctx)
  return entry(ctx, function(run)
    return convert.to_lua(run, v)
  end)
end

return M
