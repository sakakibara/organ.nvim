-- Calling `require("organ").setup({})` twice (e.g. user has it in init.lua
-- AND a plugin manager re-runs the config block, or vim.pack reloads
-- plugin/* mid-session) MUST NOT double-register listeners, autocmds,
-- timers, or watcher handles. Regression test for the lifecycle bugs:
--   * watcher.start was opening a second set of fs_event handles without
--     stopping the first → every save fired the indexer twice
--   * alarms.start was adding a second events.on("indexed", ...) listener
--     without removing the first → every "indexed" event fired N alarm
--     scans for N setup() calls
--
-- Run via: nvim --headless -l tests/double_setup_safety_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- 1. Watcher: setup() twice → still only one set of handles + one rescan timer.
-- ---------------------------------------------------------------------------
do
  local org_dir = vim.fn.tempname() .. "/org"
  vim.fn.mkdir(org_dir, "p")

  package.loaded["organ"] = nil
  package.loaded["organ.watcher"] = nil
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = true, watch_dirs = {} },
  })
  local watcher = require("organ.watcher")
  local handles_after_first = vim.tbl_count(watcher._dirs)
  local rescan_after_first = watcher._rescan ~= nil
  check(
    "watcher: first setup creates at least one handle",
    handles_after_first >= 1,
    "got " .. handles_after_first
  )

  -- Second setup() — same config, should be idempotent.
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    org_dir = org_dir,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = true, watch_dirs = {} },
  })
  local handles_after_second = vim.tbl_count(watcher._dirs)
  check(
    "watcher: second setup does NOT double the handle count",
    handles_after_second == handles_after_first,
    "first=" .. handles_after_first .. " second=" .. handles_after_second
  )
  check("watcher: rescan timer remains a single instance", watcher._rescan ~= nil)

  pcall(function()
    watcher.stop()
  end)
  vim.fn.delete(org_dir, "rf")
end

-- ---------------------------------------------------------------------------
-- 2. Alarms: setup() twice → still only one events.on("indexed", ...) listener.
-- ---------------------------------------------------------------------------
-- Real-world scenario: user calls setup() multiple times in their config
-- (no module reload). package.loaded reset would simulate vim.pack-style
-- reload, which is a different bug class — orphaned listeners in modules
-- whose reference was lost. We don't test that here; this is the more
-- common "I copy-pasted setup() into init.lua and config.lua" case.
do
  package.loaded["organ"] = nil
  package.loaded["organ.alarms"] = nil
  package.loaded["organ.events"] = nil
  local events = require("organ.events")

  -- Stub query.agenda so alarms.scan doesn't need a real DB.
  package.loaded["organ.query"] = setmetatable({}, {
    __index = function(_, k)
      if k == "agenda" then
        return function()
          return {}
        end
      end
      return nil
    end,
  })

  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    alarms = { enabled = true, scan_interval_seconds = 9999 },
  })
  local alarms = require("organ.alarms")

  -- Wait for the deferred alarms.start() that setup schedules.
  vim.wait(100)

  -- Count "indexed" → scan invocations. Patch alarms.scan to a counter
  -- AFTER the initial start (so we don't count the start's own scan).
  local fire_count = 0
  local saved_scan = alarms.scan
  alarms.scan = function(...)
    fire_count = fire_count + 1
    return saved_scan(...)
  end

  events.emit("indexed", { path = "/tmp/x.org", n_headlines = 1 })
  vim.wait(50)
  check(
    "alarms: after first setup, indexed → scan fires exactly once",
    fire_count == 1,
    "got " .. fire_count
  )

  -- SECOND setup() — without resetting any modules. Same alarms instance,
  -- same events instance. The fix in alarms.start() (track + remove the
  -- prior `state.indexed_listener`) should leave us with ONE registered
  -- listener.
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    alarms = { enabled = true, scan_interval_seconds = 9999 },
  })
  vim.wait(100) -- let the new setup's deferred alarms.start() run

  fire_count = 0
  events.emit("indexed", { path = "/tmp/y.org", n_headlines = 1 })
  vim.wait(50)
  check(
    "alarms: after SECOND setup, indexed → scan still fires only ONCE",
    fire_count == 1,
    "got " .. fire_count .. " (bug would yield 2)"
  )

  alarms.scan = saved_scan
  pcall(function()
    alarms.stop()
  end)
end

-- ---------------------------------------------------------------------------
-- 3. setup_compat_listeners: user's on_index callback fires once per event,
--    not once-per-setup-call.
-- ---------------------------------------------------------------------------
do
  package.loaded["organ"] = nil
  package.loaded["organ.events"] = nil
  local events = require("organ.events")

  local fire_count = 0
  local cb = function(_, _)
    fire_count = fire_count + 1
  end

  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    on_index = cb,
  })
  -- Re-call setup with the same callback (covers the user-supplied
  -- on_index back-compat path that wires through events).
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    on_index = cb,
  })

  events.emit("indexed", { path = "/tmp/z.org", n_headlines = 0 })
  vim.wait(50)
  check(
    "on_index back-compat: fires ONCE per indexed event after double setup",
    fire_count == 1,
    "got " .. fire_count .. " (bug would yield 2)"
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("double_setup_safety_test: PASS")
