-- Verifies organ.notifier orchestration: dispatch, set_pending replaces
-- the previous batch (cancelling old handles), past entries are dropped,
-- status() reports counts.
-- Run: nvim --headless -l tests/notifier_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Redirect stdpath("data") to a tempdir.
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
local orig_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(what)
  if what == "data" then
    return tmpdir
  end
  return orig_stdpath(what)
end

-- Stub the per-platform backend so we never touch real OS schedulers.
local mock = {
  scheduled = {},
  cancelled = {},
  cancel_all_calls = 0,
  next_handle = 0,
}
function mock.schedule(entry)
  mock.next_handle = mock.next_handle + 1
  local h = "mock-handle-" .. mock.next_handle
  mock.scheduled[#mock.scheduled + 1] = { handle = h, entry = entry }
  return h
end
function mock.cancel(handle)
  mock.cancelled[#mock.cancelled + 1] = handle
  return true
end
function mock.cancel_all()
  mock.cancel_all_calls = mock.cancel_all_calls + 1
  return true
end
function mock.status()
  return { mocked = true }
end

-- Force the platform dispatch to load our mock regardless of the OS we're
-- actually running on.
package.loaded["organ.notifier.macos"] = mock
package.loaded["organ.notifier.linux"] = mock
package.loaded["organ.notifier.windows"] = mock

local notifier = require("organ.notifier")

local now = os.time()

-- 1. set_pending with two future entries schedules both.
local r1 = notifier.set_pending({
  { id = "a", at = now + 60, title = "T1", body = "B1" },
  { id = "b", at = now + 120, title = "T2", body = "B2" },
})
assert(r1, "set_pending returns truthy")
assert(#mock.scheduled == 2, "scheduled both entries (got " .. #mock.scheduled .. ")")

local pending = notifier.list_pending()
assert(#pending == 2, "two pending in state")
assert(pending[1].handle == "mock-handle-1", "handles persisted")

-- 2. Past entries are dropped (defense in depth — alarms.lua already filters).
mock.scheduled = {}
notifier.set_pending({
  { id = "c", at = now - 60, title = "Past", body = "skip me" },
  { id = "d", at = now + 60, title = "Future", body = "schedule me" },
})
assert(#mock.scheduled == 1, "only future entry scheduled (got " .. #mock.scheduled .. ")")
assert(mock.scheduled[1].entry.id == "d", "future entry was the one")

-- 3. set_pending replaces the previous batch — old handles get cancelled.
mock.cancelled = {}
mock.scheduled = {}
notifier.set_pending({ { id = "e", at = now + 60, title = "T3", body = "B3" } })
assert(#mock.cancelled == 1, "previous handle cancelled (got " .. #mock.cancelled .. ")")
assert(#mock.scheduled == 1, "new entry scheduled")

-- 4. cancel_all wipes state + calls backend cancel + cancel_all (safety net).
mock.cancelled = {}
mock.cancel_all_calls = 0
notifier.cancel_all()
assert(#mock.cancelled >= 1, "cancelled known entries")
assert(mock.cancel_all_calls == 1, "called backend cancel_all once")
assert(#notifier.list_pending() == 0, "state empty after cancel_all")

-- 5. status() reports counts and platform.
notifier.set_pending({ { id = "f", at = now + 300, title = "Soon", body = "x" } })
local st = notifier.status()
assert(st.entries_count == 1, "status counts pending")
assert(st.next_at == now + 300, "status reports next fire time")
assert(st.supported, "status: supported (mock backend loaded)")
assert(type(st.backend) == "table" and st.backend.mocked, "status pulled backend.status()")

-- 6. set_batch fast path: when backend exposes set_batch, the orchestrator
-- routes through it (one call) instead of looping schedule() per entry.
do
  -- Reset state and install a mock with set_batch defined.
  notifier.cancel_all()
  local batch_calls = {}
  local batch_mock = {
    set_batch = function(entries)
      batch_calls[#batch_calls + 1] = entries
    end,
    -- These should NOT be called when set_batch is present:
    schedule = function()
      error("set_batch path should not call schedule()")
    end,
    cancel = function()
      error("set_batch path should not call cancel()")
    end,
    cancel_all = function()
      return true
    end,
    status = function()
      return { batch = true }
    end,
  }
  package.loaded["organ.notifier.macos"] = batch_mock
  package.loaded["organ.notifier.linux"] = batch_mock
  package.loaded["organ.notifier.windows"] = batch_mock

  local now2 = os.time()
  notifier.set_pending({
    { id = "g", at = now2 + 60, title = "BatchA", body = "x" },
    { id = "h", at = now2 + 120, title = "BatchB", body = "y" },
    { id = "i", at = now2 - 60, title = "Past", body = "drop" },
  })
  assert(#batch_calls == 1, "set_batch called exactly once (got " .. #batch_calls .. ")")
  assert(
    #batch_calls[1] == 2,
    "set_batch received only future entries (got " .. #batch_calls[1] .. ")"
  )
  assert(
    batch_calls[1][1].id == "g" and batch_calls[1][2].id == "h",
    "set_batch received both future entries in order"
  )
  -- A second set_pending replaces the prior batch by a fresh set_batch call,
  -- with NO per-entry cancel loop (cancel would have errored).
  notifier.set_pending({
    { id = "j", at = now2 + 90, title = "BatchC", body = "z" },
  })
  assert(#batch_calls == 2, "second set_pending called set_batch again")
  assert(#batch_calls[2] == 1, "second batch has the one new entry")
end

vim.fn.delete(tmpdir, "rf")
print("notifier_test: PASS")
os.exit(0)
