-- organ.elisp caps: each hostile input stops at its cap's limit result,
-- well inside 2 s of wall clock, and condition-case catches none.
--
-- Run via: nvim --headless -l tests/elisp_caps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local elisp = require("organ.elisp")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function show(r)
  return (vim.inspect(r, { depth = 2 }):gsub("\n%s*", " "))
end

-- Check that fn() returns a limit result for `cap` within 2 s.
local function limited(label, cap, fn)
  local t0 = vim.uv.hrtime()
  local r = fn()
  local ms = (vim.uv.hrtime() - t0) / 1e6
  check(
    ("%s: %s limit in %.0f ms"):format(label, cap, ms),
    r.ok == false and r.kind == "limit" and r.cap == cap and ms < 2000,
    show(r)
  )
end

limited("10 000 open parens", "depth", function()
  return elisp.read(string.rep("(", 10000))
end)

limited("10 000 quotes", "depth", function()
  return elisp.read(string.rep("'", 10000) .. "x")
end)

limited("input beyond the string cap", "string", function()
  return elisp.read(string.rep(" ", 1048576) .. "x")
end)

limited("a list beyond the list cap", "list", function()
  return elisp.read("(" .. string.rep("1 ", 100001) .. ")")
end)

do
  -- (a . a) shared 50 levels deep: 2^50 nodes when printed.
  local node = { sym = "x" }
  for _ = 1, 50 do
    node = { car = node, cdr = node }
  end
  local v = elisp.to_value(node)
  check("the 2^50-node DAG builds in 50 conses", v.ok, show(v))
  limited("printing a 2^50-node DAG", "steps", function()
    return elisp.prin1(v.value)
  end)
  limited("printed_length of a 2^50-node DAG", "steps", function()
    return elisp.printed_length(v.value)
  end)
  local t0 = vim.uv.hrtime()
  local l = elisp.to_lua(v.value)
  local ms = (vim.uv.hrtime() - t0) / 1e6
  check(
    ("to_lua of the DAG converts each shared cons once (%.0f ms)"):format(ms),
    l.ok and ms < 2000,
    show(l)
  )
end

limited("lowered steps cap", "steps", function()
  return elisp.read("(" .. string.rep("a ", 2000) .. ")", 1, { caps = { steps = 100 } })
end)

do
  local r = elisp.read("(" .. string.rep("a ", 50) .. ")", 1, { caps = { steps = 10 ^ 9 } })
  check("a cap above the default clamps to it", r.ok, show(r))
end

do
  local budget = {}
  local src = "(" .. string.rep("a ", 300) .. ")"
  local ok_count = 0
  local last
  for _ = 1, 1000 do
    last = elisp.read(src, 1, { budget = budget })
    if not last.ok then
      break
    end
    ok_count = ok_count + 1
  end
  check(
    "a shared budget ends a run of calls with a steps limit",
    last.kind == "limit" and last.cap == "steps" and ok_count > 0 and budget.steps > 0,
    show(last) .. " after " .. ok_count
  )
end

-- evaluation

local function ev(src, ctx)
  return elisp.eval_string(src, ctx)
end

local function limited_any(label, caps, fn)
  local t0 = vim.uv.hrtime()
  local r = fn()
  local ms = (vim.uv.hrtime() - t0) / 1e6
  check(
    ("%s: %s limit in %.0f ms"):format(label, tostring(r.cap), ms),
    r.ok == false and r.kind == "limit" and vim.tbl_contains(caps, r.cap) and ms < 2000,
    show(r)
  )
end

limited("(while t)", "steps", function()
  return ev("(while t)")
end)

limited_any("(while t) under a 5 ms time cap", { "steps", "time" }, function()
  return ev("(while t)", { caps = { time = 5 } })
end)

for _, profile in ipairs({ "table", "capture" }) do
  limited("self-application recursion (" .. profile .. ")", "depth", function()
    return ev(
      "(funcall (lambda (f) (funcall f f)) (lambda (f) (funcall f f)))",
      { profile = profile }
    )
  end)
  limited("apply recursion (" .. profile .. ")", "depth", function()
    return ev("(let ((f (lambda (g) (apply g (list g))))) (funcall f f))", { profile = profile })
  end)
end

limited("consumer calls in a loop", "steps", function()
  local calls = 0
  local r = ev("(while t (tick))", {
    functions = {
      tick = {
        fn = function()
          calls = calls + 1
          return 0
        end,
      },
    },
  })
  check("consumer calls are charged 1 000 steps each", calls <= 201, tostring(calls))
  return r
end)

limited_any("nested cx.eval recursion", { "depth", "steps" }, function()
  local form = elisp.read("(again)").value
  return ev("(again)", {
    functions = {
      again = {
        fn = function(_, cx)
          return cx.eval(form)
        end,
      },
    },
  })
end)

limited_any("a consumer macro recursion", { "depth", "steps" }, function()
  local form = elisp.read("(m)").value
  return ev("(m)", {
    macros = {
      m = {
        fn = function(_, cx)
          return cx.eval(form)
        end,
      },
    },
  })
end)

for _, src in ipairs({
  "(condition-case nil (while t) (t 1))",
  "(ignore-errors (while t))",
  "(condition-case nil (while t) (error 1) (:success 2))",
}) do
  limited("not caught: " .. src, "steps", function()
    return ev(src)
  end)
end

limited("not caught: depth under condition-case", "depth", function()
  return ev(
    "(condition-case nil (funcall (lambda (f) (funcall f f)) (lambda (f) (funcall f f))) (t 1))"
  )
end)

do
  local budget = {}
  local n, last = 0, nil
  for _ = 1, 10000 do
    last = ev("(dotimes (i 200))", { budget = budget })
    if not last.ok then
      break
    end
    n = n + 1
  end
  check(
    "a shared budget ends a run of evaluations with a steps limit",
    last.kind == "limit" and last.cap == "steps" and n > 0 and budget.steps > 0,
    show(last) .. " after " .. n
  )
end

-- The deepest Lua chain evaluation builds before printing: a closure
-- calls a consumer function through apply, which evaluates the next
-- call to the closure with cx.eval; at the bottom a backquote error
-- prints a 190-deep form.  mapcar and sort (with equal and value<) join
-- the chain once they exist.
do
  local deep = string.rep("(", 190) .. "x" .. string.rep(")", 190)
  local bottom_form = elisp.read("`(\\, " .. deep .. " b)").value
  local down_form = elisp.read("(funcall self self (cdr l))").value
  local ctx = {
    functions = {
      down = {
        fn = function(_, cx)
          return cx.eval(down_form)
        end,
      },
      bottom = {
        fn = function(_, cx)
          return cx.eval(bottom_form)
        end,
      },
    },
  }
  local function chain(n)
    local list = "'(" .. string.rep("1 ", n) .. ")"
    return ev(
      "(let ((f (lambda (self l) (if l (apply 'down (list l)) (bottom))))) (funcall f f "
        .. list
        .. "))",
      ctx
    )
  end
  local deepest, r, bad
  for n = 0, 200 do
    r = chain(n)
    if r.kind == "limit" then
      break
    elseif not (r.kind == "signal" and r.text and r.text:find("Multiple args to ,", 1, true)) then
      bad = r
      break
    end
    deepest = n
  end
  check(
    ("the chain reaches the depth cap after %s levels, printing at the bottom"):format(
      tostring(deepest)
    ),
    not bad and deepest and deepest > 20 and r.kind == "limit" and r.cap == "depth",
    show(bad or r)
  )
end

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nelisp caps: all checks passed")
os.exit(0)
