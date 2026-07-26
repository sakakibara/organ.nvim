-- tests/tag_inheritance_query_test.lua
-- Run via: nvim --headless -l tests/tag_inheritance_query_test.lua

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

local query = require("organ.query")
local indexer = require("organ.indexer")

local path = write_file(
  "inh.org",
  [[
#+FILETAGS: :project:
* Parent :urgent:
** Child
* Other
]]
)
indexer.index_file_sync(path)

local function titles(rows)
  local t = {}
  for _, r in ipairs(rows) do
    t[#t + 1] = r.title
  end
  table.sort(t)
  return t
end

local function assert_titles(rows, expected)
  local got = titles(rows)
  assert(
    #got == #expected,
    "expected " .. #expected .. " got " .. #got .. " (" .. table.concat(got, ",") .. ")"
  )
  for i = 1, #expected do
    assert(got[i] == expected[i], "[" .. i .. "] expected " .. expected[i] .. " got " .. got[i])
  end
end

-- inherit = true matches Parent (direct) AND Child (inherited from Parent).
do
  local rows = query.headlines({ tags = { any = { "urgent" }, inherit = true } })
  assert_titles(rows, { "Child", "Parent" })
end

-- inherit = false matches only Parent (direct).
do
  local rows = query.headlines({ tags = { any = { "urgent" }, inherit = false } })
  assert_titles(rows, { "Parent" })
end

-- inherit = true + filetag matches all three (file inherits to all).
do
  local rows = query.headlines({ tags = { any = { "project" }, inherit = true } })
  assert_titles(rows, { "Child", "Other", "Parent" })
end

-- inherit = false + filetag matches none (filetags not direct).
do
  local rows = query.headlines({ tags = { any = { "project" }, inherit = false } })
  assert_titles(rows, {})
end

-- Default config inherit=true: query without explicit inherit field
-- behaves as inherit=true.
do
  local rows = query.headlines({ tags = { any = { "urgent" } } })
  assert_titles(rows, { "Child", "Parent" })
end

-- tags.none with inherit = true excludes Child if any ancestor has the tag.
do
  local rows = query.headlines({ tags = { none = { "urgent" }, inherit = true } })
  assert_titles(rows, { "Other" })
end

io.write("tag inheritance query ok\n")
