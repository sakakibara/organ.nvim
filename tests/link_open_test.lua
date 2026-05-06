-- Unit tests for link.open — pure action-record dispatcher.
-- Run via: nvim --headless -l tests/link_open_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/lo.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.system({ "cp", root .. "/tests/fixtures/05-links.org", org_dir .. "/05.org" })

require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
})
require("organ").scan_blocking(org_dir, 5000)

local link = require("organ.link")

-- id resolvable → jump_headline
do
  local a = link.open("id:beta-id")
  assert(a.kind == "jump_headline", "kind=" .. a.kind)
  assert(a.file_path:match("05%.org$"))
  assert(type(a.line) == "number" and a.line >= 1)
end

-- id unresolvable → error
do
  local a = link.open("id:nope")
  assert(a.kind == "error", "kind=" .. a.kind)
  assert(a.reason:find("not indexed"))
end

-- file → edit_file
do
  local a = link.open("file:/x.org")
  assert(a.kind == "edit_file" and a.path == "/x.org", vim.inspect(a))
end

-- http → url
do
  local a = link.open("http://example.com")
  assert(a.kind == "url" and a.url == "http://example.com")
end

-- mailto → url
do
  local a = link.open("mailto:a@b.com")
  assert(a.kind == "url" and a.url == "mailto:a@b.com")
end

-- headline search → headline_search
do
  local a = link.open("*Gamma Section")
  assert(a.kind == "headline_search" and a.title_match == "Gamma Section")
end

-- bare path → edit_file
do
  local a = link.open("/abs/path.org")
  assert(a.kind == "edit_file" and a.path == "/abs/path.org")
end

-- unknown scheme → property_value
do
  local a = link.open("weird:thing")
  assert(a.kind == "property_value", vim.inspect(a))
  assert(a.key == "weird" and a.value == "thing", vim.inspect(a))
end

vim.fn.delete(tmp, "rf")
io.write("link open ok\n")
os.exit(0)
