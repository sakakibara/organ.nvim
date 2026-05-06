-- tests/query_stuck_test.lua
-- Run via: nvim --headless -l tests/query_stuck_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local organ = require("organ")
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

organ.setup({
  org_dir = tmpdir,
  db_path = tmpdir .. "/organ.db",
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
  stuck = { project_filter = { tags = { any = { "project" } } }, next_states = { "NEXT" } },
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
  "p.org",
  [[
* Proj1 :project:
** NEXT Pick a name
* Proj2 :project:
** TODO Plan
* Proj3 :project:
* NotProject :other:
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

----------------------------------------------------------------------
-- Default: Proj2 (TODO child) and Proj3 (no children) are stuck. Proj1 has NEXT.
do
  local stuck = query.stuck_projects()
  assert_titles(stuck, { "Proj2", "Proj3" })
end

----------------------------------------------------------------------
-- next_states = {NEXT, TODO}: only Proj3 is stuck.
do
  local stuck = query.stuck_projects({ next_states = { "NEXT", "TODO" } })
  assert_titles(stuck, { "Proj3" })
end

----------------------------------------------------------------------
-- project_filter overridden to level=1: all 4 level-1 minus those with NEXT child.
do
  local stuck = query.stuck_projects({ project_filter = { level = 1 }, next_states = { "NEXT" } })
  assert_titles(stuck, { "NotProject", "Proj2", "Proj3" })
end

io.write("query stuck ok\n")
