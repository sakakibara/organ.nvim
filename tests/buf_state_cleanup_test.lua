-- Verifies the per-buffer cleanup registry: registered teardowns run on
-- cleanup, keys are idempotent, and a second cleanup is a no-op.
-- Run via: nvim --headless -l tests/buf_state_cleanup_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local B = require("organ.buf_state")

local bufnr = 4242
local ran = {}

B.on_cleanup(bufnr, "a", function(b)
  ran[#ran + 1] = "a:" .. b
end)
B.on_cleanup(bufnr, "b", function(b)
  ran[#ran + 1] = "b:" .. b
end)
-- re-registering the same key replaces, does not accumulate
B.on_cleanup(bufnr, "a", function(b)
  ran[#ran + 1] = "a2:" .. b
end)

B.cleanup(bufnr)
table.sort(ran)
assert(#ran == 2, "exactly two teardowns ran, got " .. #ran)
assert(ran[1] == "a2:4242", "re-registered key replaced the first: " .. ran[1])
assert(ran[2] == "b:4242", "second key ran: " .. ran[2])

-- a teardown that errors does not block the others
local other_ran = false
B.on_cleanup(7, "boom", function()
  error("teardown boom")
end)
B.on_cleanup(7, "ok", function()
  other_ran = true
end)
B.cleanup(7)
assert(other_ran, "a failing teardown did not block the rest")

-- second cleanup is a no-op (bucket cleared)
local again = false
B.cleanup(bufnr)
B.on_cleanup(bufnr, "a", function()
  again = true
end)
assert(not again, "cleanup did not re-run already-cleared teardowns")

print("buf_state_cleanup_test: PASS")
