-- Watcher start opens fs_event handles for org_dir + watch_dirs;
-- stop closes them; add_dir is idempotent; restart works.
-- Extended regression net: asserts _dirs/_tombstones/_pollers are all {}
-- after stop, and that repeated start/stop cycles don't accumulate state.
-- Run via: nvim --headless -l tests/watcher_lifecycle_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local d1 = tmp .. "/d1"
vim.fn.mkdir(d1, "p")
local d2 = tmp .. "/d2"
vim.fn.mkdir(d2, "p")
local d3 = tmp .. "/d3"
vim.fn.mkdir(d3, "p")

local watcher = require("organ.watcher")

watcher.start({
  enabled = true,
  watch_dirs = { d1, d2 },
  auto_watch_buffers = false,
  delete_grace_ms = 500,
  rescan_interval_ms = 0, -- disable for this test
  scan_batch_size = 50,
  ignore = {},
  use_polling = false,
  poll_interval_ms = 5000,
}, d1) -- treat d1 as org_dir for the test (no double-watch)

local pathmod = require("organ.path")
local watched = watcher.watched_dirs()
table.sort(watched)
local expect = { pathmod.canonical(d1), pathmod.canonical(d2) }
table.sort(expect)
assert(#watched == #expect, "expected " .. #expect .. " watched, got " .. #watched)
for i, p in ipairs(expect) do
  assert(watched[i] == p, "watched[" .. i .. "]=" .. tostring(watched[i]) .. " expected " .. p)
end

assert(watcher.is_watching(d1) == true)
assert(watcher.is_watching(pathmod.canonical(d1)) == true) -- canonical lookup also works
assert(watcher.is_watching(d3) == false)

watcher.add_dir(d3)
assert(watcher.is_watching(d3) == true, "add_dir d3")

local before = #watcher.watched_dirs()
watcher.add_dir(d3) -- idempotent
assert(#watcher.watched_dirs() == before, "add_dir not idempotent")

watcher.stop()
assert(#watcher.watched_dirs() == 0, "stop did not clear _dirs")

-- After stop all three state tables must be empty (regression net).
local function tablen(t)
  local n = 0
  for _ in pairs(t or {}) do
    n = n + 1
  end
  return n
end
assert(tablen(watcher._dirs) == 0, "_dirs not empty after stop: " .. tablen(watcher._dirs))
assert(
  tablen(watcher._tombstones) == 0,
  "_tombstones not empty after stop: " .. tablen(watcher._tombstones)
)
assert(tablen(watcher._pollers) == 0, "_pollers not empty after stop: " .. tablen(watcher._pollers))

-- Repeated start/stop cycles must not accumulate state.
-- Run 5 cycles; after each stop verify the maps are clean.
local opts = {
  enabled = true,
  watch_dirs = { d1, d2 },
  auto_watch_buffers = false,
  delete_grace_ms = 500,
  rescan_interval_ms = 0,
  scan_batch_size = 50,
  ignore = {},
  use_polling = false,
  poll_interval_ms = 5000,
}
for cycle = 1, 5 do
  watcher.start(opts, d1)
  -- Verify at least d1 is watched each cycle.
  assert(watcher.is_watching(d1), "cycle " .. cycle .. ": d1 not watched")
  watcher.stop()
  local nd = tablen(watcher._dirs)
  local nt = tablen(watcher._tombstones)
  local np = tablen(watcher._pollers)
  assert(nd == 0, "cycle " .. cycle .. ": _dirs leaked: " .. nd)
  assert(nt == 0, "cycle " .. cycle .. ": _tombstones leaked: " .. nt)
  assert(np == 0, "cycle " .. cycle .. ": _pollers leaked: " .. np)
end

-- Restart works after 5 cycles.
watcher.start(opts, d1)
assert(watcher.is_watching(d1) == true, "restart after 5 cycles failed")
watcher.stop()

vim.fn.delete(tmp, "rf")
io.write("watcher lifecycle ok\n")
os.exit(0)
