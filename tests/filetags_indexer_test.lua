-- tests/filetags_indexer_test.lua
-- Run via: nvim --headless -l tests/filetags_indexer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local organ = require("organ")
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

organ.setup({
  org_dir = tmpdir,
  db_path = tmpdir .. "/organ.db",
})

local function write_file(name, content)
  local path = tmpdir .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

local function index_path(path)
  local indexer = require("organ.indexer")
  indexer.index_file_sync(path)
end

local function file_tags(path)
  -- Indexer canonicalizes file_path before writing — match here.
  path = require("organ.path").canonical(path) or path
  local h = organ.db_handle()
  local s = assert(h:prepare("SELECT tag FROM file_tags WHERE file_path = ? ORDER BY tag"))
  s:bind_text(1, path)
  local out = {}
  while s:step() == require("organ.db").SQLITE_ROW do
    out[#out + 1] = s:column_text(0)
  end
  s:finalize()
  return out
end

local function assert_eq_list(a, b, msg)
  assert(#a == #b, (msg or "") .. " list length: expected " .. #b .. " got " .. #a)
  for i = 1, #a do
    assert(a[i] == b[i], (msg or "") .. " [" .. i .. "]: expected " .. b[i] .. " got " .. a[i])
  end
end

-- Colon-delimited.
do
  local path = write_file("colon.org", "#+FILETAGS: :project:work:\n* Foo\n")
  index_path(path)
  assert_eq_list(file_tags(path), { "project", "work" }, "colon-delimited")
end

-- Space-delimited.
do
  local path = write_file("space.org", "#+FILETAGS: project work\n* Foo\n")
  index_path(path)
  assert_eq_list(file_tags(path), { "project", "work" }, "space-delimited")
end

-- Mixed-case keyword.
do
  local path = write_file("case.org", "#+filetags: :lab:\n* Foo\n")
  index_path(path)
  assert_eq_list(file_tags(path), { "lab" }, "case-insensitive keyword")
end

-- Re-index with reduced tags clears the old set.
do
  local path = write_file("reduce.org", "#+FILETAGS: :a:b:c:\n* Foo\n")
  index_path(path)
  assert_eq_list(file_tags(path), { "a", "b", "c" }, "initial three tags")
  -- Rewrite with only one tag.
  local f = assert(io.open(path, "w"))
  f:write("#+FILETAGS: :only:\n* Foo\n")
  f:close()
  index_path(path)
  assert_eq_list(file_tags(path), { "only" }, "reduced to one tag")
end

io.write("filetags indexer ok\n")
