-- tests/agenda_block_query_error_test.lua
-- Run via: nvim --headless -l tests/agenda_block_query_error_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})

local agenda = require("organ.agenda")
local query = require("organ.query")

-- Stub query.agenda: first call raises, second returns one row.
local seq = 0
local orig = query.agenda
query.agenda = function()
  seq = seq + 1
  if seq == 1 then
    error("simulated DB error")
  end
  return {
    {
      id = "r2",
      title = "T2",
      todo_state = "TODO",
      priority = "A",
      scheduled_date = "2026-04-26",
      tags = {},
      file_path = "/x.org",
      line_start = 2,
      level = 1,
    },
  }
end

local bufnr = agenda.open({
  blocks = {
    { label = "Failing", from = "today", to = "today", group_by = "none" },
    { label = "Working", from = "today", to = "today", group_by = "none" },
  },
})

query.agenda = orig

local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local has_err, has_row = false, false
for _, l in ipairs(lines) do
  if l:find("query error") and l:find("simulated DB error") then
    has_err = true
  end
  if l:find("T2") then
    has_row = true
  end
end
assert(has_err, "query error line rendered for failing block")
assert(has_row, "sibling block's row rendered despite first block error")

vim.api.nvim_buf_delete(bufnr, { force = true })
io.write("agenda block query_error ok\n")
