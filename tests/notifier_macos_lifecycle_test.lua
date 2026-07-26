-- macOS notifier: diagnose() and uninstall_bundle() — exercised against
-- our own test-controlled HOME so the user's real ~/Library/ is never
-- touched. Asserts the safety guards (path-prefix check, symlink refusal,
-- exact pattern match for LaunchAgents).
--
-- Run via: nvim --headless -l tests/notifier_macos_lifecycle_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Redirect HOME so the test never reaches into the real ~/Library.
local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")
vim.fn.mkdir(sandbox .. "/Library/LaunchAgents", "p")
vim.fn.mkdir(sandbox .. "/Library/Application Support/organ", "p")
local saved_home = os.getenv("HOME")
vim.env.HOME = sandbox
-- vim.uv.os_homedir caches the value; force a refresh.
package.loaded["organ.notifier.macos"] = nil
local mac = require("organ.notifier.macos")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- 1. diagnose(): returns a list of step records.
do
  local steps = mac.diagnose()
  check("diagnose: returns a non-empty list", type(steps) == "table" and #steps > 0)
  for i, s in ipairs(steps) do
    check(
      ("diagnose step %d has label string"):format(i),
      type(s.label) == "string" and #s.label > 0
    )
  end
end

-- 2. uninstall_bundle(): paranoia guards.

-- 2a. Symlink refusal: replace the bundle dir with a symlink, ensure
-- uninstall refuses to follow + delete.
do
  local bundle = sandbox .. "/Library/Application Support/organ/Organ.app"
  vim.fn.delete(bundle, "rf")
  local link_target = sandbox .. "/elsewhere"
  vim.fn.mkdir(link_target, "p")
  -- Create a sentinel inside the link target — uninstall must NOT delete it.
  local sentinel = link_target .. "/.sentinel"
  local fd = io.open(sentinel, "w")
  fd:write("do-not-delete")
  fd:close()
  vim.uv.fs_symlink(link_target, bundle)

  local steps = mac.uninstall_bundle()
  local refused = false
  for _, line in ipairs(steps) do
    if line:find("REFUSED", 1, true) and line:find("SYMLINK", 1, true) then
      refused = true
    end
  end
  check(
    "uninstall: refuses to delete a SYMLINK at the bundle path",
    refused,
    "steps:\n  " .. table.concat(steps, "\n  ")
  )
  check(
    "uninstall: sentinel inside the symlinked dir is untouched",
    vim.fn.filereadable(sentinel) == 1
  )

  vim.fn.delete(bundle, "rf") -- remove the symlink itself
end

-- 2b. Real bundle dir: install + uninstall round-trip.
do
  -- Create a fake bundle with sentinel files. We don't go through
  -- ensure_bundle (which would shell out to lsregister); we just lay out
  -- files and ensure uninstall removes them.
  local bundle = sandbox .. "/Library/Application Support/organ/Organ.app"
  vim.fn.mkdir(bundle .. "/Contents/MacOS", "p")
  vim.fn.mkdir(bundle .. "/Contents/Resources", "p")
  for _, p in ipairs({
    bundle .. "/Contents/Info.plist",
    bundle .. "/Contents/MacOS/organ-notify",
    bundle .. "/Contents/Resources/Organ.icns",
  }) do
    local fd = io.open(p, "w")
    fd:write("dummy")
    fd:close()
  end

  -- And add some fake LaunchAgents that look organ-owned and one that doesn't.
  for _, name in ipairs({ "sh.organ.reminder.aaa.plist", "sh.organ.reminder.bbb.plist" }) do
    local fd = io.open(sandbox .. "/Library/LaunchAgents/" .. name, "w")
    fd:write("<plist></plist>")
    fd:close()
  end
  local foreign = sandbox .. "/Library/LaunchAgents/com.example.foreign.plist"
  local fd = io.open(foreign, "w")
  fd:write("<plist></plist>")
  fd:close()

  local steps = mac.uninstall_bundle()
  check("uninstall: bundle dir removed", vim.fn.isdirectory(bundle) == 0)
  check(
    "uninstall: organ LaunchAgents removed",
    vim.fn.filereadable(sandbox .. "/Library/LaunchAgents/sh.organ.reminder.aaa.plist") == 0
      and vim.fn.filereadable(sandbox .. "/Library/LaunchAgents/sh.organ.reminder.bbb.plist") == 0
  )
  check("uninstall: foreign LaunchAgent untouched", vim.fn.filereadable(foreign) == 1)
  -- Sanity: the steps list is informative.
  check("uninstall: returns a non-empty step list", type(steps) == "table" and #steps > 0)
end

vim.env.HOME = saved_home
vim.fn.delete(sandbox, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("notifier_macos_lifecycle_test: PASS")
