-- setup_resume validates state and clears it on stale pointer.
-- Run via: nvim --headless -l tests/clock_resume_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local data_dir = tmp .. "/data"
vim.fn.mkdir(data_dir, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(w)
  if w == "data" then
    return data_dir
  end
  return original_stdpath(w)
end

local fixture = vim.fn.resolve(org_dir .. "/x.org")
local f = assert(io.open(fixture, "w"))
f:write("* Alpha\n  :PROPERTIES:\n  :ID: alpha\n  :END:\n")
f:close()

local state_mod = (function()
  -- Pre-stash a state file BEFORE setup() so resume sees it on init.
  vim.fn.mkdir(data_dir .. "/organ", "p")
  local sj = data_dir .. "/organ/clock.json"
  local fh = assert(io.open(sj, "w"))
  fh:write(vim.fn.json_encode({
    file_path = fixture,
    line_start = 0,
    headline_id = "alpha",
    start_ts = os.time() - 600,
    started_at = "x",
  }))
  fh:close()
  return require("organ.clock.state")
end)()

require("organ").setup({
  db_path = tmp .. "/c.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  mtime_skip = false,
  hash_skip = false,
})

-- 1. Valid state survives setup_resume.
do
  local clock = require("organ.clock")
  if clock.setup_resume then
    clock.setup_resume()
  end
  local s = state_mod.load()
  assert(s and s.headline_id == "alpha", "valid state should remain")
end

-- 2. Stale state (file vanished) → cleared.
do
  state_mod.save({
    file_path = "/nonexistent/x.org",
    line_start = 0,
    headline_id = "ghost",
    start_ts = os.time(),
    started_at = "x",
  })
  local clock = require("organ.clock")
  if clock.setup_resume then
    clock.setup_resume()
  end
  assert(state_mod.load() == nil, "stale state should be cleared")
end

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmp, "rf")
io.write("clock resume ok\n")
os.exit(0)
