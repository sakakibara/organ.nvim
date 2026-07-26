-- tests/clock_idle_test.lua
-- Run via: nvim --headless -l tests/clock_idle_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local organ = require("organ")
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")
organ.setup({
  org_dir = tmpdir,
  db_path = tmpdir .. "/organ.db",
  clock = { state_path = tmpdir .. "/clock.json" },
})

local clock = require("organ.clock")
local state = require("organ.clock.state")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- subtract_idle moves active clock's start_ts forward.
do
  -- Manually seed an active clock.
  state.save({
    active = { start_ts = 1000, file_path = "/x.org", headline_id = "h1", drawer = "LOGBOOK" },
  })
  local err = clock.subtract_idle(120)
  assert_eq(err, nil)
  local s = state.load()
  assert_eq(s.active.start_ts, 1120, "start_ts moved forward by 120 seconds")
end

-- subtract_idle with no active clock returns error.
do
  state.clear()
  local err = clock.subtract_idle(60)
  assert(err and err:find("no active"), "got: " .. tostring(err))
end

-- idle.start with nil/0 threshold is a no-op.
do
  local idle = require("organ.clock.idle")
  idle.stop() -- ensure clean
  idle.start(nil)
  -- No autocmd group registered.
  -- nvim_get_autocmds errors if group doesn't exist; pcall it.
  local ok = pcall(vim.api.nvim_get_autocmds, { group = "organ_clock_idle" })
  assert(not ok, "no autocmd group when threshold is nil")
end

-- idle.start with threshold registers autocmds + timer.
do
  local idle = require("organ.clock.idle")
  idle.stop()
  idle.start(5) -- 5-minute threshold
  local autos = vim.api.nvim_get_autocmds({ group = "organ_clock_idle" })
  assert(#autos > 0, "autocmds registered")
  idle.stop() -- cleanup
end

-- Threshold reached: prompt-handler "Subtract" path adjusts state.
do
  state.save({
    active = { start_ts = 5000, file_path = "/x.org", headline_id = "h1", drawer = "LOGBOOK" },
  })
  local idle = require("organ.clock.idle")
  -- Stub vim.ui.select to immediately pick "Subtract" (idx=2).
  local saved = vim.ui.select
  vim.ui.select = function(items, opts, cb)
    cb(items[2], 2)
  end
  idle._test_trigger(180) -- simulate 180 seconds idle
  vim.ui.select = saved
  local s = state.load()
  assert_eq(s.active.start_ts, 5180, "subtract path adjusted state")
end

io.write("clock idle ok\n")
