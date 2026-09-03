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
  attach = { dir = tmp .. "/data" },
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

-- attachment: → edit_file under the headline's attachment directory
-- (Emacs `org-attach-follow` -> `org-attach-expand` + `org-link-open-as-file`).
do
  local att_path = org_dir .. "/att.org"
  local f = assert(io.open(att_path, "w"))
  f:write(table.concat({
    "* With id",
    "  :PROPERTIES:",
    "  :ID:       0192abcdef1234567890abcdef123456",
    "  :END:",
    "  [[attachment:report.pdf]]",
    "* Without id",
    "  [[attachment:other.pdf]]",
    "",
  }, "\n"))
  f:close()
  local b = vim.fn.bufadd(att_path)
  vim.fn.bufload(b)
  local expect_dir = tmp .. "/data/01/92abcdef1234567890abcdef123456"

  local a = link.open("attachment:report.pdf", att_path, { bufnr = b, line = 5 })
  assert(a.kind == "edit_file", vim.inspect(a))
  assert(a.path == expect_dir .. "/report.pdf", vim.inspect(a))
  assert(a.anchor == nil, vim.inspect(a))

  a = link.open("attachment:notes.org::*Sec", att_path, { bufnr = b, line = 5 })
  assert(a.kind == "edit_file", vim.inspect(a))
  assert(a.path == expect_dir .. "/notes.org" and a.anchor == "*Sec", vim.inspect(a))

  a = link.open("attachment:other.pdf", att_path, { bufnr = b, line = 7 })
  assert(a.kind == "error", vim.inspect(a))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  assert(#lines == 7 and lines[6] == "* Without id", "follow must not create an ID drawer")
end

vim.fn.delete(tmp, "rf")
io.write("link open ok\n")
os.exit(0)
