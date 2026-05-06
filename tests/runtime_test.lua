-- tests/runtime_test.lua
-- Verify that runtime.db() opens the DB on first call and returns the same
-- handle on second call (singleton behaviour).
-- Run via: nvim --headless -l tests/runtime_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

-- Setup organ so config is populated (runtime.db() reads config.db_path).
require("organ").setup({
  org_dir = tmpdir,
  db_path = tmpdir .. "/organ_runtime.db",
})

local runtime = require("organ.runtime")

-- Call 1: should open the DB and return a valid handle.
local h1 = runtime.db()
assert(h1 ~= nil, "runtime.db() returned nil on first call")

-- Call 2: should return the exact same handle (cached).
local h2 = runtime.db()
assert(h1 == h2, "runtime.db() returned a different handle on second call")

-- Verify we can prepare a statement (i.e. the handle is functional).
local stmt = h1:prepare("SELECT 1")
assert(stmt ~= nil, "prepared statement failed on runtime.db() handle")
stmt:finalize()

print("runtime ok")
