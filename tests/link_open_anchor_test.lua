-- Unit tests for link.open with anchor + source-file-relative path expansion.
-- Run via: nvim --headless -l tests/link_open_anchor_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/notes"
vim.fn.mkdir(org_dir, "p")
local source_file = org_dir .. "/main.org"
local fh = assert(io.open(source_file, "w"))
fh:write("placeholder\n")
fh:close()

require("organ").setup({
  db_path = tmp .. "/lo.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local link = require("organ.link")

-- Anchor flows through to action.anchor.
do
  local a = link.open("file:x.org::*Heading", source_file)
  assert(a.kind == "edit_file", "kind=" .. tostring(a.kind))
  assert(a.anchor == "*Heading", "anchor=" .. tostring(a.anchor))
end

-- No anchor → action.anchor is nil.
do
  local a = link.open("file:x.org", source_file)
  assert(a.kind == "edit_file")
  assert(a.anchor == nil, "anchor should be nil; got " .. tostring(a.anchor))
end

-- Sibling (no leading ./) → resolved relative to source dir.
do
  local a = link.open("file:sibling.org", source_file)
  assert(
    a.path == org_dir .. "/sibling.org",
    "expected " .. org_dir .. "/sibling.org; got " .. tostring(a.path)
  )
end

-- ./ prefix → resolved relative to source dir.
do
  local a = link.open("file:./other.org", source_file)
  assert(
    a.path == org_dir .. "/./other.org",
    "expected " .. org_dir .. "/./other.org; got " .. tostring(a.path)
  )
end

-- Subdir-relative → joined under source dir.
do
  local a = link.open("file:sub/x.org", source_file)
  assert(
    a.path == org_dir .. "/sub/x.org",
    "expected " .. org_dir .. "/sub/x.org; got " .. tostring(a.path)
  )
end

-- Absolute path → kept as-is.
do
  local a = link.open("file:/abs/path.org", source_file)
  assert(a.path == "/abs/path.org", "expected /abs/path.org; got " .. tostring(a.path))
end

-- ~ expansion.
do
  local a = link.open("file:~/foo.org", source_file)
  local home = vim.fn.expand("~")
  assert(a.path == home .. "/foo.org", "expected " .. home .. "/foo.org; got " .. tostring(a.path))
end

-- $VAR expansion (using HOME, which is set in any test env).
do
  local a = link.open("file:$HOME/bar.org", source_file)
  local home = vim.fn.expand("$HOME")
  assert(a.path == home .. "/bar.org", "expected " .. home .. "/bar.org; got " .. tostring(a.path))
end

-- No source_file_path → cwd-relative fallback (fnamemodify :p).
do
  local a = link.open("file:cwdrel.org", nil)
  assert(a.path:sub(1, 1) == "/", "cwd-relative should yield absolute path; got " .. a.path)
  assert(a.path:match("/cwdrel%.org$"), "expected suffix /cwdrel.org; got " .. a.path)
end

-- Anchor + path resolution combined.
do
  local a = link.open("file:notes.org::42", source_file)
  assert(a.path == org_dir .. "/notes.org", "path=" .. tostring(a.path))
  assert(a.anchor == "42", "anchor=" .. tostring(a.anchor))
end

vim.fn.delete(tmp, "rf")
io.write("link open anchor ok\n")
os.exit(0)
