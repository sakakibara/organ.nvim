-- Verifies that the items handed to the picker backend carry
-- display_segments for every source kind: headlines, links, files.
-- Catches the case where a new picker entry-point starts using a
-- source whose builder forgets to populate segments, leaving that
-- picker rendering monochrome on telescope/fzf-lua/snacks.
--
-- Uses the _test_stub backend so no real picker UI opens.
--
-- Run via: nvim --headless -l tests/find_picker_segments_test.lua

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
vim.fn.writefile({
  "#+TITLE: Notes",
  "",
  "* TODO Plan release",
  "  :PROPERTIES:",
  "  :ID: 1234abcd",
  "  :END:",
  "* DONE Older",
  "* Refers to [[id:1234abcd][release]]",
}, org_dir .. "/notes.org")
vim.fn.writefile({
  "#+TITLE: Inbox",
  "",
  "* Item",
}, org_dir .. "/inbox.org")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

local stub = require("organ.find.backend")._test_stub

local function items_have_segments(items)
  if not items or #items == 0 then
    return false, "no items"
  end
  for i, it in ipairs(items) do
    if not it.display_segments or #it.display_segments == 0 then
      return false, "item " .. i .. " missing display_segments: " .. vim.inspect(it)
    end
  end
  return true
end

-- (a) :Org find file -> source = "files".
do
  stub.last = nil
  vim.cmd("Org find file")
  check("find_file invoked picker", stub.last ~= nil)
  if stub.last then
    local ok, why = items_have_segments(stub.last.items)
    check("find_file: every file item has display_segments", ok, why)
  end
end

-- (b) :Org find -> source = "headlines".
do
  stub.last = nil
  vim.cmd("Org find")
  check("find invoked picker", stub.last ~= nil)
  if stub.last then
    local ok, why = items_have_segments(stub.last.items)
    check("find: every headline item has display_segments", ok, why)
  end
end

-- (c) :Org roam -> source = "headlines" with has_id filter.
do
  stub.last = nil
  vim.cmd("Org roam")
  check("roam invoked picker", stub.last ~= nil)
  if stub.last then
    local ok, why = items_have_segments(stub.last.items)
    check("roam: every roam-node item has display_segments", ok, why)
  end
end

-- (d) :Org find link -> source = "links".  Skip cleanly if the
-- index has no link rows for this fixture.
do
  stub.last = nil
  vim.cmd("Org find link")
  if stub.last and stub.last.items and #stub.last.items > 0 then
    local ok, why = items_have_segments(stub.last.items)
    check("find_link: every link item has display_segments", ok, why)
  else
    print("SKIP  find_link: no link rows in index")
  end
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("find_picker_segments_test: PASS")
