-- roam.create_node(title) opens an unsaved buffer for
-- <dir>/<YYYYMMDDHHMMSS>-<slug>.org (matching Emacs org-roam's default
-- capture name) seeded with :ID:, #+title:, cursor at the trailing blank
-- line; the file reaches disk only on write. Honors file_template.
-- Run via: nvim --headless -l tests/roam_create_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local roam_dir = tmp .. "/roam"

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  roam = { dir = roam_dir },
})

local roam = require("organ.roam")

-- Default file path: <roam_dir>/<YYYYMMDDHHMMSS>-<slug>.org
-- A fresh node opens unsaved; write it so the on-disk assertions below apply.
roam.create_node("Hello World!")
assert(vim.bo.modified, "fresh node should open as an unsaved buffer")
vim.cmd("write")
local matches = vim.fn.glob(roam_dir .. "/*-hello_world.org", false, true)
assert(
  #matches == 1,
  "expected one timestamped match for hello_world; got: " .. vim.inspect(matches)
)
local expected = matches[1]
assert(
  expected:match("/(%d%d%d%d%d%d%d%d%d%d%d%d%d%d)%-hello_world%.org$"),
  "expected `<14-digit>-hello_world.org`; got " .. vim.fn.fnamemodify(expected, ":t")
)

-- Body has :ID:, #+title:, blank trailing.
local lines = vim.fn.readfile(expected)
local has_id, has_title = false, false
for _, ln in ipairs(lines) do
  if ln:match("^:ID:%s+%x") then
    has_id = true
  end
  if ln == "#+title: Hello World!" then
    has_title = true
  end
end
assert(has_id, "expected :ID: line; got:\n" .. table.concat(lines, "\n"))
assert(has_title, "expected #+title:; got:\n" .. table.concat(lines, "\n"))

-- ID matches v7 regex.
local id = nil
for _, ln in ipairs(lines) do
  id = ln:match("^:ID:%s+(%S+)")
  if id then
    break
  end
end
assert(
  id and id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"),
  "id doesn't match v7 shape: " .. tostring(id)
)

-- Idempotent: second call resolves to the same file, no twin.
local before = vim.fn.readfile(expected)
roam.create_node("Hello World!")
local matches_after = vim.fn.glob(roam_dir .. "/*-hello_world.org", false, true)
assert(
  #matches_after == 1 and matches_after[1] == expected,
  "second create_node call wrote a twin: " .. vim.inspect(matches_after)
)
local after = vim.fn.readfile(expected)
assert(
  table.concat(before, "\n") == table.concat(after, "\n"),
  "second create_node call overwrote the file"
)

-- file_template override.
require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  roam = {
    dir = roam_dir,
    file_template = function(title)
      return "custom-" .. title:lower():gsub("%s", "_") .. ".org"
    end,
  },
})
roam.create_node("Override Me")
vim.cmd("write")
assert(
  vim.loop.fs_stat(roam_dir .. "/custom-override_me.org"),
  "expected file_template override path"
)

-- Empty / whitespace-only title is rejected with a notify; no file
-- written, no buffer opened.  Without this guard the picker's
-- create-action chord on an empty prompt would silently produce
-- `untitled.org` (slugify's empty-string fallback).
do
  local pre_files = vim.fn.glob(roam_dir .. "/*.org", false, true)
  for _, t in ipairs({ "", "   ", "\t" }) do
    roam.create_node(t)
  end
  local post_files = vim.fn.glob(roam_dir .. "/*.org", false, true)
  assert(
    #pre_files == #post_files,
    string.format(
      "empty-title create_node should not write a new file (pre=%d post=%d)",
      #pre_files,
      #post_files
    )
  )
  for _, p in ipairs(post_files) do
    assert(
      not p:match("/%.org$") and not p:match("/untitled%.org$"),
      "empty-title create_node leaked a file: " .. p
    )
  end
end

vim.fn.delete(tmp, "rf")
io.write("roam create ok\n")
os.exit(0)
