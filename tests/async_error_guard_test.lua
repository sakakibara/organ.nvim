-- Regression: an error thrown inside a SCHEDULED boundary must reach
-- on_error and must not poison the scheduler.  pcall cannot catch a throw
-- on a later vim.schedule stack, so the convention wraps scheduled
-- callbacks in errors.guard at the boundary; this locks that in.
-- Run via: nvim --headless -l tests/async_error_guard_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local E = require("organ.errors")
local organ = require("organ")

local got
local saved_cfg = organ.config
organ.config = {
  on_error = function(e)
    got = e
  end,
}
local notify = require("organ.notify")
local orig = notify.error
notify.error = function() end

local ran_after = false
vim.schedule(E.guard("organ.test.async", function()
  error("async boom")
end))
vim.schedule(function()
  ran_after = true
end)
vim.wait(500, function()
  return got ~= nil and ran_after
end)

notify.error = orig
organ.config = saved_cfg

assert(
  got and tostring(got):find("async boom", 1, true),
  "scheduled guarded error reached on_error"
)
assert(ran_after, "scheduler kept running after a guarded error (no crash)")

print("async_error_guard_test: PASS")
