-- A template organ cannot capture into is refused when the capture
-- starts, before a capture buffer opens and the user types an entry.
-- Run via: nvim --headless -l tests/capture_start_refusal_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local errors = {}
package.loaded["organ.notify"] = {
  error = function(msg)
    errors[#errors + 1] = msg
  end,
  warn = function() end,
  info = function() end,
}

local capture = require("organ.capture")
local before = #vim.api.nvim_list_bufs()
capture.start({ name = "no path", target = { kind = "file" }, body = "* %?" }, {})

local failures = 0
if #vim.api.nvim_list_bufs() ~= before then
  failures = failures + 1
  io.write("FAIL a capture buffer opened for a template with no path\n")
end
if #errors ~= 1 or not errors[1]:find("target.path required", 1, true) then
  failures = failures + 1
  io.write("FAIL expected one refusal naming the problem, got " .. vim.inspect(errors) .. "\n")
end
if failures > 0 then
  os.exit(1)
end
io.write("capture start refusal ok\n")
