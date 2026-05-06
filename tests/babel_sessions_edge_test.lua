-- Babel sessions: edge cases beyond the happy path.
--
-- Covers:
--   * timeout: body that produces no output for the sentinel
--   * broken body: syntax error in python — error visible in output, session
--     remains usable for the next call (REPL doesn't crash on tracebacks)
--   * stop_session during use: subsequent eval respawns
--   * large output: body that prints many KB doesn't lose data
--
-- Run via: nvim --headless -l tests/babel_sessions_edge_test.lua

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

-- 1. Timeout: a body that loops forever (or in this case, sleeps longer
-- than our wait) → eval returns nil + a timeout err. Use a short
-- timeout to keep the test fast; the body is `sleep 5` but we wait 200ms.
do
  local out, err = sessions.eval("sh", "timeout_a", "sleep 5", 200)
  check("timeout: eval returns nil", out == nil)
  check(
    "timeout: err mentions 'timed out'",
    err and err:find("timed out") ~= nil,
    "got err: " .. tostring(err)
  )
  -- Important: even after a timeout the session is still alive — the
  -- subprocess wasn't killed, just the wait gave up. Subsequent eval
  -- must NOT spawn a fresh shell (unless the user explicitly stops it),
  -- but the previous body's output may still be in the buffer. We
  -- verify the session module's API by issuing a stop+ensure.
  sessions.stop_session("sh", "timeout_a")
  check(
    "after stop: timeout_a is gone from list",
    (function()
      for _, s in ipairs(sessions.list()) do
        if s.key == "sh:timeout_a" then
          return false
        end
      end
      return true
    end)()
  )
end

-- 2. Broken python body: SyntaxError. Session still usable afterward.
if vim.fn.executable("python3") == 1 then
  -- Provoke a syntax error.
  local out1, err1 = sessions.eval("python", "edge", "1 +", 5000)
  check(
    "python broken body: eval returns (something, nil) — output captured",
    err1 == nil,
    "err1=" .. tostring(err1)
  )
  check(
    "python broken body: output mentions SyntaxError",
    out1 and out1:lower():find("syntaxerror") ~= nil,
    "out1=" .. vim.inspect(out1)
  )
  -- Session must survive the error and accept a new evaluation.
  local out2, err2 = sessions.eval("python", "edge", "print(40 + 2)", 5000)
  check("python after-error: session still alive", err2 == nil, "err2=" .. tostring(err2))
  check(
    "python after-error: subsequent eval still works (prints 42)",
    out2 and out2:find("42") ~= nil,
    "out2=" .. vim.inspect(out2)
  )
  sessions.stop_session("python", "edge")
else
  print("SKIP  python broken-body tests (python3 not on PATH)")
end

-- 3. stop_session mid-flight: kill while a body might still be writing.
-- We start a session, then immediately stop it; ensure the next eval
-- spawns fresh and works.
do
  sessions.eval("sh", "respawn", "true", 1000)
  sessions.stop_session("sh", "respawn")
  local out, err = sessions.eval("sh", "respawn", "echo respawned", 5000)
  check(
    "after stop: re-eval spawns fresh + returns expected output",
    err == nil and out and out:find("respawned", 1, true) ~= nil,
    "out=" .. vim.inspect(out) .. " err=" .. tostring(err)
  )
  sessions.stop_session("sh", "respawn")
end

-- 4. Large output: body that emits ~10KB shouldn't be truncated.
do
  local body = 'for i in $(seq 1 1000); do echo "line-$i"; done'
  local out, err = sessions.eval("sh", "big", body, 10000)
  check("large output: eval succeeded", err == nil, tostring(err))
  check("large output: contains line-1", out and out:find("line-1\n", 1, true) ~= nil)
  check(
    "large output: contains line-1000 (no truncation)",
    out and out:find("line-1000", 1, true) ~= nil
  )
  sessions.stop_session("sh", "big")
end

-- 5. stop_all idempotency.
sessions.stop_all()
sessions.stop_all() -- no error on second call
check("stop_all is idempotent", true)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_sessions_edge_test: PASS")
