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
  local out1, err1 = sessions.eval("sh", "test", "X=hello", 5000)
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
else
  print("SKIP  python session test (python3 not on PATH)")
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
