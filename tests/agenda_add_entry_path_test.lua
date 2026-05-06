-- agenda M-CR add-entry path validation: refuses non-.org extensions
-- and paths outside config.org_dir. Was added as a security/data-loss
-- guard in commit 2cf6a30.
--
-- Run via: nvim --headless -l tests/agenda_add_entry_path_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
-- Resolve so canonical comparison below is symmetric.
org_dir = vim.fn.resolve(org_dir)

require("organ").setup({
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local agenda = require("organ.agenda")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Empty / nil → false.
local ok, why = agenda.add_entry_path_ok("")
check("empty path is rejected", ok == false)
check("empty path: reason given", type(why) == "string")

ok = agenda.add_entry_path_ok(nil)
check("nil path is rejected", ok == false)

-- .txt is rejected.
ok, why = agenda.add_entry_path_ok(org_dir .. "/notes.txt")
check(".txt extension rejected", ok == false)
check(
  ".txt: reason mentions non-.org",
  why and why:find("non%-?%.org") ~= nil,
  "got: " .. tostring(why)
)

-- /etc/passwd is rejected on extension AND on prefix.
ok = agenda.add_entry_path_ok("/etc/passwd")
check("/etc/passwd is rejected", ok == false)

-- /tmp/foo.org is rejected on prefix (org_dir is /tmp/<random>/org).
ok, why = agenda.add_entry_path_ok("/tmp/foo.org")
check(".org outside org_dir is rejected", ok == false)
check(
  "outside-org_dir: reason mentions org_dir",
  why and why:find("org_dir") ~= nil,
  "got: " .. tostring(why)
)

-- A .org file inside org_dir is accepted.
ok = agenda.add_entry_path_ok(org_dir .. "/inbox.org")
check(".org inside org_dir is accepted", ok == true)

-- A .org_archive file inside org_dir is accepted.
ok = agenda.add_entry_path_ok(org_dir .. "/done.org_archive")
check(".org_archive inside org_dir is accepted", ok == true)

-- Nested path inside org_dir is accepted.
vim.fn.mkdir(org_dir .. "/sub", "p")
ok = agenda.add_entry_path_ok(org_dir .. "/sub/notes.org")
check("nested .org inside org_dir is accepted", ok == true)

-- When config.org_dir is empty (rare; user opted out of workspace),
-- only the extension rule applies; any .org path is allowed.
require("organ").config.org_dir = ""
ok = agenda.add_entry_path_ok("/anywhere/x.org")
check("with empty org_dir: any .org path is allowed", ok == true)
ok = agenda.add_entry_path_ok("/anywhere/x.txt")
check("with empty org_dir: .txt still rejected", ok == false)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_add_entry_path_test: PASS")
