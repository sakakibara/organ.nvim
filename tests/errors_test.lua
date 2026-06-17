-- Verifies organ.errors check/guard primitives.
-- Run via: nvim --headless -l tests/errors_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local E = require("organ.errors")

-- check passes truthy values through
assert(E.check(5, "ctx", "msg") == 5, "check returns the value on success")
assert(E.check("x", "ctx", "msg") == "x", "check returns truthy strings")

-- check raises with context on a falsy condition
local ok, err = pcall(E.check, nil, "organ.db", "handle missing")
assert(not ok, "check raises on falsy")
assert(
  tostring(err):find("organ.db: handle missing", 1, true),
  "error carries ctx and msg: " .. tostring(err)
)

-- guard reports a thrown error via notify.error and returns nil
local notify = require("organ.notify")
local orig = notify.error
local captured
notify.error = function(m)
  captured = m
end
local r = E.guard("organ.cmd.foo", function()
  error("boom")
end)()
notify.error = orig
assert(r == nil, "guard returns nil on caught error")
assert(captured and captured:find("organ.cmd.foo", 1, true), "report carries ctx")
assert(captured and captured:find("boom", 1, true), "report carries the error text")

-- guard routes to config.on_error when set
local organ = require("organ")
local saved_cfg = organ.config
organ.config = {
  on_error = function(e)
    organ._last_on_error = e
  end,
}
notify.error = function() end
E.guard("organ.cmd.bar", function()
  error("kaboom")
end)()
notify.error = orig
organ.config = saved_cfg
assert(
  organ._last_on_error and tostring(organ._last_on_error):find("kaboom", 1, true),
  "on_error invoked"
)

-- guard passes the result through on success
assert(E.guard("x", function()
  return 42
end)() == 42, "guard forwards success result")

print("errors_test: PASS")
