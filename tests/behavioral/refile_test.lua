-- Behavioral test: refile a subtree to a target picked from the find list.
--
-- Uses the `_test_stub` find backend so the picker doesn't open a real
-- UI; the test instead inspects the captured items list and fires the
-- refile_here action directly.  Verifies the subtree leaves the source
-- file and lands under the chosen target headline.
--
-- Exercises:
--   :Org refile -> organ.refile.commands.refile
--   organ.refile.refile (column choice, target filter, find.pick call)
--   find.make_refile_action -> organ.refile.move
--   buffer mutation + target file write
--
-- Run via: nvim --headless -l tests/behavioral/refile_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

local src_file = org_dir .. "/inbox.org"
local dst_file = org_dir .. "/projects.org"
vim.fn.writefile({
  "#+TITLE: Inbox",
  "",
  "* TODO Refile me",
  "  body line",
}, src_file)
vim.fn.writefile({
  "#+TITLE: Projects",
  "",
  "* Backlog",
  "* Roadmap",
}, dst_file)

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

vim.cmd("filetype plugin on")
vim.cmd("edit " .. src_file)
local src_buf = vim.api.nvim_get_current_buf()
vim.wait(500, function()
  return vim.bo[src_buf].filetype == "org"
end)

-- Cursor on the headline that will be refiled (line 3).
vim.api.nvim_win_set_cursor(0, { 3, 0 })

-- Trigger refile.  Picker is the test stub; it just captures items.
local stub = require("organ.find.backend")._test_stub
stub.last = nil
vim.cmd("Org refile")

check("picker stub captured invocation", stub.last ~= nil)
check(
  "default action is refile_here",
  stub.last and stub.last.opts.default_action == "refile_here",
  stub.last and stub.last.opts.default_action or "(nil)"
)

-- Find the "Backlog" target in the captured items.
local target_item
for _, it in ipairs(stub.last.items or {}) do
  if it.title == "Backlog" then
    target_item = it
    break
  end
end
check("captured items include the Backlog target", target_item ~= nil)

-- Fire the refile_here action with the target.
if target_item then
  stub.last.opts.actions.refile_here(target_item)
end

-- Source buffer should no longer have "Refile me".
do
  local lines = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
  local has_refile = false
  for _, l in ipairs(lines) do
    if l:match("Refile me") then
      has_refile = true
    end
  end
  check(
    "post: source buffer no longer has the refiled headline",
    not has_refile,
    table.concat(lines, "|")
  )
end

-- Target file should now contain "Refile me" demoted under Backlog.
do
  local arc = vim.fn.readfile(dst_file)
  local has_refile, has_backlog = false, false
  for _, l in ipairs(arc) do
    if l:match("Backlog") then
      has_backlog = true
    end
    if l:match("Refile me") then
      has_refile = true
    end
  end
  check("post: target file still has Backlog", has_backlog)
  check("post: target file received the refiled subtree", has_refile, table.concat(arc, "|"))
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("refile_test: PASS")
