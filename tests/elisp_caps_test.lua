-- organ.elisp caps: each hostile input stops at its cap's limit result,
-- well inside 2 s of wall clock.
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

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nelisp caps: all checks passed")
os.exit(0)
