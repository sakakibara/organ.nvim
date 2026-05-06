-- Unit tests for link.open — unknown-scheme links return the
-- property_value action shape.
-- Run via: nvim --headless -l tests/link_open_property_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/notes"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/po.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local link = require("organ.link")

-- ROAM_REFS-style.
do
  local a = link.open("ROAM_REFS:https://a.com")
  assert(a.kind == "property_value", "kind=" .. tostring(a.kind))
  assert(a.key == "ROAM_REFS", "key=" .. tostring(a.key))
  assert(a.value == "https://a.com", "value=" .. tostring(a.value))
end

-- Generic property name.
do
  local a = link.open("BIBKEY:knuth1984")
  assert(a.kind == "property_value")
  assert(a.key == "BIBKEY")
  assert(a.value == "knuth1984")
end

-- Empty value still produces a property_value action.
do
  local a = link.open("ROAM_REFS:")
  assert(a.kind == "property_value")
  assert(a.key == "ROAM_REFS")
  assert(a.value == "")
end

-- Reserved schemes UNCHANGED.
do
  local a = link.open("http://example.com")
  assert(
    a.kind == "url" and a.url == "http://example.com",
    "http should still be url; got " .. vim.inspect(a)
  )
end

do
  local a = link.open("file:/abs/path.org")
  assert(
    a.kind == "edit_file" and a.path == "/abs/path.org",
    "file should still be edit_file; got " .. vim.inspect(a)
  )
end

vim.fn.delete(tmp, "rf")
io.write("link open property ok\n")
os.exit(0)
