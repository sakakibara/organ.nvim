-- Regression: startup/bulk indexing must not spam one INFO notification
-- per file. Per-file "indexed N headlines from <path>" is debug-only
-- (surfaces only under log_level = "debug"); a single INFO summary
-- "indexed N headline(s) across M file(s)" fires once a scan finishes.
--
-- Run via: nvim --headless -l tests/index_notify_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = "/tmp/organ_index_notify"
vim.fn.delete(tmp, "rf")
vim.fn.mkdir(tmp, "p")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

vim.fn.writefile({ "* TODO one", "* TODO two" }, tmp .. "/a.org")
vim.fn.writefile({ "* three" }, tmp .. "/b.org")

local captured = {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  captured[#captured + 1] = { msg = msg, level = level }
end

local organ = require("organ")
organ.setup({
  org_dir = tmp,
  notify = true,
  scan_on_startup = false,
  watcher = { enabled = false },
  db_path = tmp .. "/organ.db",
})

local queue = require("organ.queue")

local function run_scan()
  organ._start_scan()
  organ._scan_walk(tmp, function()
    organ._poll_scan_completion()
  end)
end

local function has(pattern)
  for _, n in ipairs(captured) do
    if n.msg and n.msg:match(pattern) then
      return n.msg
    end
  end
  return nil
end

local function count(pattern)
  local c = 0
  for _, n in ipairs(captured) do
    if n.msg and n.msg:match(pattern) then
      c = c + 1
    end
  end
  return c
end

-- Phase A: default log_level. No per-file lines, exactly one summary.
run_scan()
assert(
  vim.wait(20000, function()
    return queue.is_empty() and has("across %d+ file") ~= nil
  end, 20),
  "scan did not finish or summary never fired"
)
-- Let any trailing scheduled notifies flush.
vim.wait(200)

check(
  "no per-file 'headlines from' notification at default log_level",
  count("headlines from") == 0
)
local summary = has("indexed %d+ headline%(s%) across %d+ file%(s%)")
check("one summary notification fired", summary ~= nil, "captured " .. vim.inspect(captured))
if summary then
  check("summary counts 2 files", summary:match("across (%d+) file") == "2", summary)
  check("summary counts 3 headlines", summary:match("indexed (%d+) headline") == "3", summary)
end

-- Phase B: log_level = "debug" surfaces the per-file lines. Force a real
-- re-extract by disabling the skip fast-paths.
captured = {}
organ.config.log_level = "debug"
organ.config.mtime_skip = false
organ.config.hash_skip = false
run_scan()
assert(
  vim.wait(20000, function()
    return queue.is_empty() and count("headlines from") >= 2
  end, 20),
  "debug per-file lines never surfaced"
)
check("per-file 'headlines from' lines surface under log_level=debug", count("headlines from") >= 2)

vim.notify = real_notify

if fails > 0 then
  error(fails .. " check(s) failed")
end
print("\nAll checks passed.")
