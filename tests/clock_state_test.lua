-- Unit tests for clock.state — load/save/clear of clock.json.
-- Run via: nvim --headless -l tests/clock_state_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local data_dir = tmp .. "/data"
vim.fn.mkdir(data_dir, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(what)
  if what == "data" then
    return data_dir
  end
  return original_stdpath(what)
end

local state = require("organ.clock.state")

-- 1. load() on missing file → nil.
do
  local s = state.load()
  assert(s == nil, "expected nil; got " .. vim.inspect(s))
end

-- 2. save() then load() → identical table.
do
  local payload = {
    file_path = "/abs/x.org",
    line_start = 42,
    headline_id = "abc-123",
    start_ts = 1745673000,
    started_at = "2026-04-26 14:30",
  }
  state.save(payload)
  local s = state.load()
  assert(s, "load should return state")
  assert(s.file_path == "/abs/x.org")
  assert(s.line_start == 42)
  assert(s.headline_id == "abc-123")
  assert(s.start_ts == 1745673000)
  assert(s.started_at == "2026-04-26 14:30")
end

-- 3. clear() removes file; subsequent load → nil.
do
  state.clear()
  local s = state.load()
  assert(s == nil, "after clear, load should be nil; got " .. vim.inspect(s))
end

-- 4. Malformed JSON → load returns nil (not error).
do
  local path = data_dir .. "/organ/clock.json"
  vim.fn.mkdir(data_dir .. "/organ", "p")
  local f = assert(io.open(path, "w"))
  f:write("{not valid json")
  f:close()
  local s = state.load()
  assert(s == nil, "malformed JSON should yield nil")
end

-- 5. save() creates parent dir if missing.
do
  vim.fn.delete(data_dir .. "/organ", "rf")
  state.save({
    file_path = "/x.org",
    line_start = 0,
    headline_id = "id",
    start_ts = 1,
    started_at = "x",
  })
  assert(vim.loop.fs_stat(data_dir .. "/organ"), "parent dir should exist")
  assert(vim.loop.fs_stat(data_dir .. "/organ/clock.json"), "file should exist")
end

-- A file holding the state under an `active` key loads as the flat state.
do
  state.save({
    active = {
      file_path = "/abs/n.org",
      line_start = 3,
      headline_id = "nested",
      start_ts = 5,
    },
  })
  local s = state.load()
  assert(s and s.active == nil, "nested state flattened; got " .. vim.inspect(s))
  assert(s.file_path == "/abs/n.org" and s.line_start == 3 and s.headline_id == "nested")
  state.clear()
end

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmp, "rf")
io.write("clock state ok\n")
os.exit(0)
