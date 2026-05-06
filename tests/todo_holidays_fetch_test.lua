-- holidays.fetch spawns curl via vim.system (mocked), writes the response
-- body to the cache file.
-- Run via: nvim --headless -l tests/todo_holidays_fetch_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

-- Mock vim.system. The original is restored at the end (best-effort).
local original_vim_system = vim.system
vim.system = function(cmd, _opts, cb)
  -- Accept either curl args or a stub. Verify it's a curl invocation.
  assert(cmd[1] == "curl", "expected curl, got " .. tostring(cmd[1]))
  -- Pretend curl succeeded with a JSON body.
  cb({ code = 0, stdout = '[{"date":"2026-01-01","name":"New Year"}]' })
  -- Return a minimal handle.
  return { wait = function() end, kill = function() end, pid = 0 }
end

local hol = require("organ.holidays")
hol._cache_dir = function()
  return tmp
end

local got_ok, got_err
hol.fetch("JP", 2026, function(ok, err)
  got_ok, got_err = ok, err
end)
vim.wait(200, function()
  return got_ok ~= nil
end, 10)

assert(got_ok == true, "fetch should succeed: err=" .. tostring(got_err))

-- Cache file should now exist with the expected content.
local fh = assert(io.open(tmp .. "/JP-2026.json", "r"))
local body = fh:read("*a")
fh:close()
assert(body:find("New Year", 1, true), "cache body: " .. body)

-- HTTP 404 → empty cache file ([]) and ok=true (so we don't retry every setup).
vim.system = function(cmd, _opts, cb)
  cb({ code = 22, stdout = "", stderr = "curl: (22) HTTP 404" })
  return { wait = function() end, kill = function() end, pid = 0 }
end
got_ok, got_err = nil, nil
hol.fetch("XX", 2026, function(ok, err)
  got_ok, got_err = ok, err
end)
vim.wait(200, function()
  return got_ok ~= nil
end, 10)
assert(
  got_ok == true,
  "404 should still resolve ok with empty cache; got err=" .. tostring(got_err)
)
local fh2 = assert(io.open(tmp .. "/XX-2026.json", "r"))
local body2 = fh2:read("*a")
fh2:close()
assert(body2 == "[]", "404 cache should be []; got '" .. body2 .. "'")

vim.system = original_vim_system
vim.fn.delete(tmp, "rf")
io.write("todo holidays fetch ok\n")
os.exit(0)
