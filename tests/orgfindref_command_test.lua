-- :Org find ref no-arg defaults to ROAM_REFS; with arg filters by KEY;
-- tab-completion lists DISTINCT property keys.
-- Run via: nvim --headless -l tests/orgfindref_command_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/notes"
vim.fn.mkdir(org_dir, "p")

local fixture = org_dir .. "/refs.org"
local fh = assert(io.open(fixture, "w"))
fh:write([=[* HasRoam
  :PROPERTIES:
  :ROAM_REFS: https://r.example.com
  :END:

* HasBibkey
  :PROPERTIES:
  :BIBKEY: knuth1984
  :END:

* HasCustom
  :PROPERTIES:
  :MYPROP: foo
  :END:
]=])
fh:close()

require("organ").setup({
  db_path = tmp .. "/r.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

assert(vim.api.nvim_get_commands({}).Org, ":Org not registered")
assert(require("organ").cmd("find ref"), "subcommand `find_ref` not registered in :Org dispatcher")

local stub = require("organ.find.backend")._test_stub

-- 1. No-arg defaults to ROAM_REFS → only HasRoam item.
do
  stub.last = nil
  vim.cmd("Org find ref")
  assert(stub.last and stub.last.items, "picker should fire")
  assert(#stub.last.items == 1, "expected 1 item; got " .. #stub.last.items)
  assert(
    stub.last.items[1].title == "HasRoam",
    "expected HasRoam; got " .. tostring(stub.last.items[1].title)
  )
end

-- 2. Explicit BIBKEY → only HasBibkey item.
do
  stub.last = nil
  vim.cmd("Org find ref BIBKEY")
  assert(stub.last and stub.last.items, "picker should fire")
  assert(#stub.last.items == 1)
  assert(stub.last.items[1].title == "HasBibkey")
end

-- 3. Explicit MYPROP → only HasCustom item.
do
  stub.last = nil
  vim.cmd("Org find ref MYPROP")
  assert(stub.last and stub.last.items, "picker should fire")
  assert(#stub.last.items == 1)
  assert(stub.last.items[1].title == "HasCustom")
end

-- 4. Tab completion returns DISTINCT property keys (or those starting
--    with the lead).
do
  local completions = vim.fn.getcompletion("Org find ref ", "cmdline")
  local seen = {}
  for _, c in ipairs(completions) do
    seen[c] = true
  end
  assert(seen["ROAM_REFS"], "ROAM_REFS should appear in completions: " .. vim.inspect(completions))
  assert(seen["BIBKEY"], "BIBKEY should appear: " .. vim.inspect(completions))
  assert(seen["MYPROP"], "MYPROP should appear: " .. vim.inspect(completions))
end

-- 5. Prefix filter on completion: "B" → only BIBKEY.
do
  local completions = vim.fn.getcompletion("Org find ref B", "cmdline")
  assert(
    #completions == 1 and completions[1] == "BIBKEY",
    "expected ['BIBKEY']; got " .. vim.inspect(completions)
  )
end

vim.fn.delete(tmp, "rf")
io.write("OrgFindRef ok\n")
os.exit(0)
