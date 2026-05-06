-- organ.profile: wraps hot-path functions, records call counts +
-- durations, prints a sorted report on stop.
--
-- Run via: nvim --headless -l tests/profile_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local profile = require("organ.profile")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

check("starts disabled", profile.is_enabled() == false)
profile.start({ slow_ms = 5 })
check("enabled after start", profile.is_enabled() == true)

-- Make a few calls through wrapped functions. query.headlines is one
-- of the wrapped paths.
local query = require("organ.query")
for _ = 1, 3 do
  pcall(query.headlines, {})
end

-- Force-record a slow synthetic call so we have a slow_count > 0 to
-- exercise the report's "slow examples" branch.
profile._records["fake.slow"] = {
  count = 2,
  total_ms = 200,
  max_ms = 150,
  slow_count = 2,
  examples = { { dt_ms = 150, extra = "/tmp/a.org" }, { dt_ms = 50, extra = "/tmp/b.org" } },
}

local rows, out = profile.report()
check("report returns rows", type(rows) == "table" and #rows > 0)
check("report mentions fake.slow", out:find("fake.slow", 1, true) ~= nil)
check("report mentions query.headlines", out:find("organ.query.headlines", 1, true) ~= nil)
check("report includes slow-examples block", out:find("Slow examples", 1, true) ~= nil)
check("report shows slow-example detail (path)", out:find("/tmp/a.org", 1, true) ~= nil)

profile.stop()
check("disabled after stop", profile.is_enabled() == false)

-- Re-start clears records (so a fresh session isn't polluted by old data).
profile.start()
check("records cleared on restart", profile._records["fake.slow"] == nil)
profile.stop()

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("profile_test: PASS")
