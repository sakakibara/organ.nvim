-- queue.enqueue_* called BEFORE queue.init() must not throw and must
-- not warn — the module-load seed buffers items, and `init()` carries
-- them over.  Regression test for the original "flood of stack
-- traces from pre-init events" bug AND the follow-up "spurious
-- warnings about dropped items in lazy-load order" bug.
--
-- Run via: nvim --headless -l tests/queue_uninit_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Capture warnings.
local notes = {}
local saved_notify = vim.notify
vim.notify = function(msg, _level, _opts)
  notes[#notes + 1] = msg
end

-- Reload queue cleanly so we hit the un-init state.
package.loaded["organ.queue"] = nil
local queue = require("organ.queue")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- 1. Calling enqueue before init must NOT throw.
local ok, err = pcall(queue.enqueue_background, "/tmp/foo.org")
check("enqueue_background pre-init: does not throw", ok, "err: " .. tostring(err))

local ok2, err2 = pcall(queue.enqueue_interactive, "/tmp/bar.org")
check("enqueue_interactive pre-init: does not throw", ok2, "err: " .. tostring(err2))

-- 2. Many pre-init calls produce ZERO warnings (they're queued in
-- the module-load seed and adopted by init()).
for _ = 1, 50 do
  pcall(queue.enqueue_background, "/tmp/repeated.org")
end
vim.wait(50)

local n_warn = 0
for _, m in ipairs(notes) do
  if m:find("organ.queue", 1, true) then
    n_warn = n_warn + 1
  end
end
check(
  "50 pre-init enqueues produce 0 warnings (silent buffering)",
  n_warn == 0,
  "got " .. n_warn .. " warns: " .. vim.inspect(notes)
)

-- 3. init() carries pre-init items over.  Track which paths the
-- new state's `process` callback receives.  Loop-wait (rather than
-- a fixed sleep) because the queue drains via vim.schedule and
-- needs the event loop to tick.
local processed = {}
queue.init({
  process = function(path, _tier, done)
    processed[path] = true
    done()
  end,
  debounce_ms = 0,
})
vim.wait(500, function()
  return processed["/tmp/foo.org"] and processed["/tmp/bar.org"]
end, 10)
check(
  "init() carried over /tmp/foo.org from pre-init",
  processed["/tmp/foo.org"] == true,
  "processed: " .. vim.inspect(processed)
)
check("init() carried over /tmp/bar.org from pre-init", processed["/tmp/bar.org"] == true)

-- Post-init enqueue still returns true normally.
check("after init: enqueue_background returns true", queue.enqueue_background("/tmp/x.org") == true)

vim.notify = saved_notify

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("queue_uninit_test: PASS")
