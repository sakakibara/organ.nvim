-- Babel sessions: persistent interpreter per (lang, session-name).
--
-- Variables and imports persist across calls within the same session.
-- This test uses `sh` because every test environment has it; python
-- is opportunistic.
--
-- Run via: nvim --headless -l tests/babel_sessions_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local sessions = require("organ.babel.sessions")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- 1. sh session: variables persist across two calls.
do
  local _, err1 = sessions.eval("sh", "test", "X=hello", 5000)
  check("sh first eval did not error", err1 == nil, tostring(err1))
  local out2, err2 = sessions.eval("sh", "test", 'echo "$X world"', 5000)
  check("sh second eval did not error", err2 == nil, tostring(err2))
  check(
    "sh session: X carried across blocks → 'hello world' in output",
    out2 and out2:find("hello world", 1, true) ~= nil,
    "got: " .. vim.inspect(out2)
  )
end

-- 2. Different session names → independent state.
do
  sessions.eval("sh", "alpha", "Y=alpha-val", 5000)
  sessions.eval("sh", "beta", "Y=beta-val", 5000)
  local out_a = sessions.eval("sh", "alpha", 'echo "$Y"', 5000) or ""
  local out_b = sessions.eval("sh", "beta", 'echo "$Y"', 5000) or ""
  check(
    "alpha session sees 'alpha-val'",
    out_a:find("alpha-val", 1, true) ~= nil,
    "got: " .. vim.inspect(out_a)
  )
  check(
    "beta session sees 'beta-val' (independent)",
    out_b:find("beta-val", 1, true) ~= nil,
    "got: " .. vim.inspect(out_b)
  )
end

-- 3. list() reports the active sessions.
local active = sessions.list()
check("list() reports ≥ 3 sessions (sh:test, sh:alpha, sh:beta)", #active >= 3, "got " .. #active)

-- 4. stop_session(lang, name) removes one.
sessions.stop_session("sh", "test")
local active2 = sessions.list()
local has_test = false
for _, s in ipairs(active2) do
  if s.key == "sh:test" then
    has_test = true
  end
end
check("stop_session('sh','test') removes only that one", not has_test)

-- 5. Python session (only when python3 available).
if vim.fn.executable("python3") == 1 then
  local _, err = sessions.eval("python", "py1", "x = 7", 5000)
  check("python first eval no error", err == nil, tostring(err))
  local out, err2 = sessions.eval("python", "py1", "print(x * 2)", 5000)
  check(
    "python: x persists across blocks (printed 14)",
    out and out:find("14") ~= nil and err2 == nil,
    "out=" .. vim.inspect(out) .. " err=" .. tostring(err2)
  )
  local function trim(s)
    return s and (s:gsub("%s+$", "")) or nil
  end
  local loop = sessions.eval("python", "py1", "for i in range(2):\n    print(i)", 5000)
  check(
    "python: compound statement runs as a unit (Emacs: 0 / 1)",
    trim(loop) == "0\n1",
    "got: " .. vim.inspect(loop)
  )
  local two = sessions.eval("python", "py1", "x = 5\nprint(x * 2)", 5000)
  check(
    "python: no REPL prompt or banner in output",
    trim(two) == "10",
    "got: " .. vim.inspect(two)
  )
  local bad = sessions.eval("python", "py1", "1 +", 5000)
  check(
    "python: syntax error text captured, without prompts",
    bad and bad:find("SyntaxError", 1, true) ~= nil and bad:find(">>>", 1, true) == nil,
    "got: " .. vim.inspect(bad)
  )
  local after = sessions.eval("python", "py1", "print('still %d' % x)", 5000)
  check(
    "python: session usable after error",
    trim(after) == "still 5",
    "got: " .. vim.inspect(after)
  )
else
  print("SKIP  python session test (python3 not on PATH)")
end

-- 5b. An eval consumes the sentinel's whole line, so no byte of it stays in
-- flight to land at the head of the next eval's output.
-- (`sh -i` writes its prompt to stderr, which sh sessions merge, so only
-- the sentinel invariants are asserted here, not overall cleanliness.)
do
  local out1 = sessions.eval("sh", "drain", "echo one", 5000) or ""
  check("drain: first eval sees its output", out1:find("one", 1, true) ~= nil, vim.inspect(out1))
  check(
    "drain: the sentinel never reaches the caller",
    not out1:find("__ORG_BABEL_END_", 1, true),
    vim.inspect(out1)
  )
  for _, s in pairs(sessions._sessions) do
    check(
      "drain: no sentinel line left buffered",
      not s.out:find("__ORG_BABEL_END_", 1, true),
      vim.inspect(s.out)
    )
  end
  local out2 = sessions.eval("sh", "drain", "echo two", 5000) or ""
  check(
    "drain: next eval does not inherit the sentinel's newline",
    out2:sub(1, 1) ~= "\n",
    vim.inspect(out2)
  )
  check("drain: next eval sees its own output", out2:find("two", 1, true) ~= nil, vim.inspect(out2))
end

-- 6. stop_all wipes all sessions.
sessions.stop_all()
check("stop_all() leaves zero active sessions", #sessions.list() == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_sessions_test: PASS")
