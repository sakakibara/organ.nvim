-- tests/aliases_query_test.lua
-- Run via: nvim --headless -l tests/aliases_query_test.lua

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

local indexer = require("organ.indexer")
local query = require("organ.query")

local path = write_file(
  "q.org",
  '* Real Title\n  :PROPERTIES:\n  :ID:       n1\n  :ROAM_ALIASES: alt "alt name"\n  :END:\n'
    .. "* Other Title\n  :PROPERTIES:\n  :ID:       n2\n  :END:\n"
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

local function assert_eq_list(a, b, msg)
  assert(#a == #b, (msg or "") .. " len " .. #a .. " vs " .. #b)
  for i = 1, #a do
    assert(a[i] == b[i], (msg or "") .. " [" .. i .. "] " .. a[i] .. " vs " .. b[i])
  end
end

----------------------------------------------------------------------
-- Default match_aliases=true: search "alt" matches via alias.
do
  local rows = query.headlines({ title_match = "alt" })
  assert_eq_list(titles(rows), { "Real Title" })
end

----------------------------------------------------------------------
-- Quoted alias also matches.
do
  local rows = query.headlines({ title_match = "alt name" })
  assert_eq_list(titles(rows), { "Real Title" })
end

----------------------------------------------------------------------
-- Disable match_aliases: "alt" no longer matches.
do
  local rows = query.headlines({ title_match = "alt", match_aliases = false })
  assert_eq_list(titles(rows), {})
end

----------------------------------------------------------------------
-- Title substring still matches with default.
do
  local rows = query.headlines({ title_match = "Real" })
  assert_eq_list(titles(rows), { "Real Title" })
end

io.write("aliases query ok\n")
