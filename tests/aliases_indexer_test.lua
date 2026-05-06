-- tests/aliases_indexer_test.lua
-- Run via: nvim --headless -l tests/aliases_indexer_test.lua

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

local function aliases_for(path)
  -- Match the indexer's canonical form (symlinks resolved + absolute)
  -- — required since BPC b1c4f29 made indexer.index_file_sync canonicalize
  -- before write.
  path = require("organ.path").canonical(path) or path
  local h = organ.db_handle()
  local s = assert(h:prepare([[
    SELECT alias FROM aliases a JOIN headlines h ON h.id = a.headline_id
     WHERE h.file_path = ? ORDER BY alias
  ]]))
  s:bind_text(1, path)
  local out = {}
  while s:step() == require("organ.db").SQLITE_ROW do
    out[#out + 1] = s:column_text(0)
  end
  s:finalize()
  return out
end

local function assert_eq_list(a, b, msg)
  assert(#a == #b, (msg or "") .. " len " .. #a .. " vs " .. #b)
  for i = 1, #a do
    assert(a[i] == b[i], (msg or "") .. " [" .. i .. "] " .. a[i] .. " vs " .. b[i])
  end
end

----------------------------------------------------------------------
-- Unquoted aliases.
do
  local path = write_file(
    "a1.org",
    "* Heading\n  :PROPERTIES:\n  :ID:       n1\n  :ROAM_ALIASES: alt one_word\n  :END:\n"
  )
  indexer.index_file_sync(path)
  assert_eq_list(aliases_for(path), { "alt", "one_word" })
end

----------------------------------------------------------------------
-- Quoted aliases with spaces.
do
  local path = write_file(
    "a2.org",
    '* Heading\n  :PROPERTIES:\n  :ID:       n2\n  :ROAM_ALIASES: "alt name" other\n  :END:\n'
  )
  indexer.index_file_sync(path)
  assert_eq_list(aliases_for(path), { "alt name", "other" })
end

----------------------------------------------------------------------
-- Re-index with reduced aliases drops the old set (CASCADE on headline rewrite).
do
  local path = write_file(
    "a3.org",
    "* Heading\n  :PROPERTIES:\n  :ID:       n3\n  :ROAM_ALIASES: a b c\n  :END:\n"
  )
  indexer.index_file_sync(path)
  assert_eq_list(aliases_for(path), { "a", "b", "c" })
  -- Rewrite with only one alias.
  local f = assert(io.open(path, "w"))
  f:write("* Heading\n  :PROPERTIES:\n  :ID:       n3\n  :ROAM_ALIASES: only\n  :END:\n")
  f:close()
  indexer.index_file_sync(path)
  assert_eq_list(aliases_for(path), { "only" })
end

io.write("aliases indexer ok\n")
