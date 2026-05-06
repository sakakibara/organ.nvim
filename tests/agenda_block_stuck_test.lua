-- tests/agenda_block_stuck_test.lua
-- Run via: nvim --headless -l tests/agenda_block_stuck_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local organ = require("organ")
local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

organ.setup({
  org_dir = tmpdir,
  db_path = tmpdir .. "/organ.db",
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
})

local function write_file(name, content)
  local path = tmpdir .. "/" .. name
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

local indexer = require("organ.indexer")
local agenda = require("organ.agenda")

local path = write_file(
  "p.org",
  [[
* Proj1 :project:
** NEXT Done item
* Proj2 :project:
** TODO Plan
]]
)
indexer.index_file_sync(path)

local bufnr = agenda.open({
  blocks = {
    { label = "Stuck", kind = "stuck" },
  },
})

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local seen_proj2, seen_proj1 = false, false
for _, l in ipairs(lines) do
  if l:find("Proj2") then
    seen_proj2 = true
  end
  if l:find("Proj1") then
    seen_proj1 = true
  end
end
assert(seen_proj2, "Proj2 (stuck) should appear")
assert(not seen_proj1, "Proj1 (has NEXT child) should NOT appear")

vim.api.nvim_buf_delete(bufnr, { force = true })
io.write("agenda block stuck ok\n")
