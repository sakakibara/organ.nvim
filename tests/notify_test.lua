-- notify helper: prefix, level routing, mute, repeat-suppress.
-- Run via: nvim --headless -l tests/notify_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function fresh_setup(opts)
  require("organ").config = require("organ.defaults")
  require("organ").setup(vim.tbl_deep_extend("force", {
    db_path = vim.fn.tempname() .. ".db",
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  }, opts or {}))
end

local notify = require("organ.notify")

-- Capture vim.notify so we can assert on it.
local captured
local orig = vim.notify
vim.notify = function(msg, lvl)
  captured = { msg = msg, lvl = lvl }
end

-- 1. Default config: every level fires; "organ:" prefix prepended.
fresh_setup({ notify = true })
captured = nil
notify.info("hello")
assert(captured and captured.msg == "organ: hello", "info prefix")
assert(captured.lvl == vim.log.levels.INFO, "info level")

-- Reset suppression so the next call isn't deduped.
notify.repeat_suppress_seconds = 0

captured = nil
notify.warn("bar")
assert(captured.msg == "organ: bar" and captured.lvl == vim.log.levels.WARN, "warn")

captured = nil
notify.error("oops")
assert(captured.msg == "organ: oops" and captured.lvl == vim.log.levels.ERROR, "error")

-- 2. cfg.notify = false suppresses INFO + WARN; ERROR still fires.
fresh_setup({ notify = false })
captured = nil
notify.info("muted")
assert(captured == nil, "info should be muted when cfg.notify=false")
captured = nil
notify.warn("muted")
assert(captured == nil, "warn should be muted")
captured = nil
notify.error("not muted")
assert(
  captured and captured.msg == "organ: not muted",
  "error should still fire even when notify=false"
)

-- 3. Repeat suppression collapses identical (level, body) within window.
fresh_setup({ notify = true })
notify.repeat_suppress_seconds = 60
captured = nil
notify.info("dup")
assert(captured and captured.msg == "organ: dup", "first fires")
captured = nil
notify.info("dup")
assert(captured == nil, "second within window suppressed")
captured = nil
notify.info("different")
assert(captured and captured.msg == "organ: different", "different body fires")

-- 4. notify.notify with explicit level.
fresh_setup({ notify = true })
notify.repeat_suppress_seconds = 0
captured = nil
notify.notify(vim.log.levels.WARN, "explicit")
assert(
  captured and captured.lvl == vim.log.levels.WARN and captured.msg == "organ: explicit",
  "explicit-level call"
)

-- 5. debug only fires when log_level = "debug".
fresh_setup({ notify = true, log_level = "info" })
captured = nil
notify.debug("dbg")
assert(captured == nil, "debug suppressed when log_level=info")

fresh_setup({ notify = true, log_level = "debug" })
captured = nil
notify.debug("dbg")
assert(captured and captured.msg == "organ: dbg", "debug fires when log_level=debug")

vim.notify = orig
io.write("notify ok\n")
os.exit(0)
