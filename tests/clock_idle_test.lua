-- tests/clock_idle_test.lua
-- Run via: nvim --headless -l tests/clock_idle_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local organ = require("organ")
local tmpdir = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmpdir, "p")
local data_dir = tmpdir .. "/data"
vim.fn.mkdir(data_dir, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(w)
  if w == "data" then
    return data_dir
  end
  return original_stdpath(w)
end
organ.setup({
  org_dir = tmpdir,
  db_path = tmpdir .. "/organ.db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local clock = require("organ.clock")
local state = require("organ.clock.state")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

local function fixture_buf(name)
  local path = tmpdir .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write("* Task\n  body\n")
  f:close()
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function clock_lines(b)
  local out = {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if l:match("^%s*CLOCK:") then
      out[#out + 1] = l
    end
  end
  return out
end

-- subtract_idle behaves like Emacs `org-clock-resolve` "s": the running
-- clock is closed at the idle start and a fresh clock opens now.
do
  state.clear()
  local b = fixture_buf("a.org")
  clock.start({ bufnr = b, line = 1 })
  local before = state.load()
  assert(before and before.start_ts, "clock started")
  -- Pretend the clock has been running for an hour, idle for the last 10 min.
  before.start_ts = before.start_ts - 3600
  state.save(before)
  local err = clock.subtract_idle(600)
  assert_eq(err, nil, "subtract_idle")
  local s = state.load()
  assert(s and s.start_ts and s.start_ts >= os.time() - 5, "new clock started now")
  assert_eq(s.file_path, before.file_path, "same file")
  assert_eq(s.line_start, before.line_start, "same headline")
  local cl = clock_lines(b)
  assert_eq(#cl, 2, "closed clock + fresh open clock; got:\n" .. table.concat(cl, "\n"))
  assert(cl[1]:match("^%s*CLOCK: %[[^%]]+%]%s*$"), "newest line is open: " .. cl[1])
  local expected_end = os.date("[%Y-%m-%d %a %H:%M]", os.time() - 600)
  assert(cl[2]:find("--" .. expected_end, 1, true), "closed at idle start: " .. cl[2])
  clock.stop()
end

-- A clock that had barely started when idling began is cancelled and
-- restarted instead of closing a near-zero entry (Emacs `start-over`).
do
  state.clear()
  local b = fixture_buf("b.org")
  clock.start({ bufnr = b, line = 1 })
  local err = clock.subtract_idle(600)
  assert_eq(err, nil, "subtract_idle barely started")
  local cl = clock_lines(b)
  assert_eq(#cl, 1, "only the restarted clock remains; got:\n" .. table.concat(cl, "\n"))
  assert(cl[1]:match("^%s*CLOCK: %[[^%]]+%]%s*$"), "restarted clock is open: " .. cl[1])
  assert(state.load(), "state present after restart")
  clock.stop()
end

-- subtract_idle with no active clock returns error.
do
  state.clear()
  local err = clock.subtract_idle(60)
  assert(err and err:find("no active"), "got: " .. tostring(err))
end

-- Emacs `org-clock-resolve-clock` remembers the clocked entry with a
-- marker, so text inserted above it cannot move the restart onto a
-- different headline.
do
  state.clear()
  local path = tmpdir .. "/marker.org"
  local f = assert(io.open(path, "w"))
  f:write("* Alpha\n* Beta\n  b\n")
  f:close()
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local b = vim.api.nvim_get_current_buf()
  clock.start({ bufnr = b, line = 2 })
  local before = state.load()
  before.start_ts = before.start_ts - 3600
  state.save(before)
  vim.api.nvim_buf_set_lines(b, 0, 0, false, { "#+TITLE: t" })
  local err = clock.subtract_idle(600)
  assert_eq(err, nil, "subtract_idle after an edit above the headline")
  local cl = clock_lines(b)
  assert_eq(#cl, 2, "one closed + one open clock; got:\n" .. table.concat(cl, "\n"))
  local open = 0
  for _, l in ipairs(cl) do
    if l:match("^%s*CLOCK: %[[^%]]+%]%s*$") then
      open = open + 1
    end
  end
  assert_eq(open, 1, "exactly one open clock; got:\n" .. table.concat(cl, "\n"))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local s = state.load()
  assert_eq(lines[(s.line_start or 0) + 1], "* Beta", "restarted on the clocked headline")
  clock.stop()
end

-- A stop that could not find its CLOCK line is a failure, and
-- subtract_idle must not report success or open a second clock.
do
  state.clear()
  local b = fixture_buf("desync.org")
  clock.start({ bufnr = b, line = 1 })
  local before = state.load()
  before.start_ts = before.start_ts - 3600
  state.save(before)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Task", "  body" })
  local err = clock.subtract_idle(600)
  assert(err and err:find("out of sync"), "got: " .. tostring(err))
  assert_eq(#clock_lines(b), 0, "no clock opened after a failed stop")
  assert_eq(state.load(), nil, "state cleared after a failed stop")
end

-- A state file written without `line_start` must not crash cancel.
do
  state.clear()
  local b = fixture_buf("nostart.org")
  clock.start({ bufnr = b, line = 1 })
  local s = state.load()
  s.line_start = nil
  state.save(s)
  local ok, err = pcall(clock.cancel)
  assert(ok, "cancel without line_start: " .. tostring(err))
  assert_eq(#clock_lines(b), 0, "cancel removed the open clock")
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

-- Threshold reached: prompt-handler "Subtract" path closes and restarts.
do
  state.clear()
  local b = fixture_buf("c.org")
  clock.start({ bufnr = b, line = 1 })
  local before = state.load()
  before.start_ts = before.start_ts - 3600
  state.save(before)
  local idle = require("organ.clock.idle")
  -- Stub vim.ui.select to immediately pick "Subtract" (idx=2).
  local saved = vim.ui.select
  vim.ui.select = function(items, _opts, cb)
    cb(items[2], 2)
  end
  idle._test_trigger(180) -- simulate 180 seconds idle
  vim.ui.select = saved
  local s = state.load()
  assert(s and s.start_ts >= os.time() - 5, "subtract path restarted the clock")
  assert_eq(#clock_lines(b), 2, "subtract path closed the old clock")
  clock.stop()
end

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmpdir, "rf")
io.write("clock idle ok\n")
