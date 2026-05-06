-- tests/agenda_block_views_test.lua
-- Run via: nvim --headless -l tests/agenda_block_views_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

local organ = require("organ")
organ.setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = {
    views = {
      daily = {
        blocks = {
          { label = "Today", from = "today", to = "today", group_by = "none" },
          { label = "Stuck", from = "today", to = "today", group_by = "none" },
        },
      },
      bad = { from = "today", blocks = { { label = "X" } } },
    },
  },
})

local query = require("organ.query")
query.agenda = function()
  return {}
end

-- Good view opens a buffer.
vim.cmd("Org agenda daily")
local bufnr = vim.api.nvim_get_current_buf()
local agenda = require("organ.agenda")
local view = agenda.buf_state(bufnr).view
assert(view and #view.blocks == 2, "daily view opened with 2 blocks")
vim.api.nvim_buf_delete(bufnr, { force = true })

-- Bad view: capture vim.notify, ensure no agenda buffer is created.
local notified = nil
local orig_notify = vim.notify
vim.notify = function(msg, level)
  notified = msg
end
vim.cmd("Org agenda bad")
vim.notify = orig_notify
assert(notified and notified:find("cannot mix"), "notify mentions mix; got: " .. tostring(notified))
-- A new buffer may exist because Vim creates a scratch on cmd-line entry,
-- but no buffer should be filetype=organ-agenda.
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "organ-agenda" then
    error("organ-agenda buffer leaked despite normalize error")
  end
end

vim.fn.delete(tmp, "rf")
io.write("agenda block views ok\n")
os.exit(0)
