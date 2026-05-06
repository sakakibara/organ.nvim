-- timezone.detect_country() reads /etc/localtime symlink and maps IANA zone
-- to ISO country code via the bundled table.
-- Run via: nvim --headless -l tests/todo_timezone_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tz = require("organ.todo.timezone")

-- Inject a stub readlink for deterministic testing.
tz._readlink = function(path)
  return "/var/db/timezone/zoneinfo/Asia/Tokyo"
end
assert(tz.detect_country() == "JP", "Asia/Tokyo → JP")

tz._readlink = function(path)
  return "/usr/share/zoneinfo/America/New_York"
end
assert(tz.detect_country() == "US", "America/New_York → US")

-- Missing symlink → nil
tz._readlink = function(path)
  return nil
end
assert(tz.detect_country() == nil, "missing symlink → nil")

-- Unknown zone → nil
tz._readlink = function(path)
  return "/usr/share/zoneinfo/Mars/Olympus"
end
assert(tz.detect_country() == nil, "unknown zone → nil")

io.write("todo timezone ok\n")
os.exit(0)
