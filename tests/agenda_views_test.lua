-- :Org agenda <name> resolves to a configured view; tab-completion lists views;
-- global agenda.line_format is inherited when the view doesn't set its own.
-- Run via: nvim --headless -l tests/agenda_views_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

local fmt_global = function(r)
  return "<global> " .. (r.title or "?")
end

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = {
    line_format = fmt_global,
    default_view = {
      from = "today",
      to = "today",
      types = { "scheduled" },
      group_by = "none",
    },
    views = {
      ["today"] = {
        from = "today",
        to = "today",
        types = { "scheduled" },
        group_by = "none",
      },
      ["myview"] = {
        from = "today",
        to = "today",
        types = { "scheduled" },
        group_by = "none",
        line_format = function(r)
          return "[v] " .. r.title
        end,
      },
    },
  },
})

-- Tab-completion lists configured views.
assert(vim.api.nvim_get_commands({}).Org, ":Org dispatcher not registered")
assert(require("organ").cmd("agenda"), "subcommand `agenda` missing on :Org")
-- Inspect the configured views directly.
local configured = {}
for k in pairs(require("organ").config.agenda.views) do
  configured[k] = true
end
assert(configured["today"], "view 'today' missing")
assert(configured["myview"], "view 'custom' missing")

-- :Org agenda today opens an agenda buffer.
vim.cmd("Org agenda today")
local bufnr = vim.api.nvim_get_current_buf()
assert(
  vim.bo[bufnr].filetype == "organ-agenda",
  "expected organ-agenda, got " .. vim.bo[bufnr].filetype
)

-- Buffer state should carry the resolved view including the inherited
-- line_format (the "today" view did not set its own).
local state = vim.b[bufnr].organ_agenda
assert(
  state and state.view and state.view.blocks[1].line_format == fmt_global,
  "global line_format should be inherited by views that don't set their own"
)

vim.api.nvim_buf_delete(bufnr, { force = true })

-- A view-set line_format wins over the global one.  Note: the view
-- name must NOT collide with reserved hierarchical actions
-- (`day`, `week`, `todos`, `tags`, `search`, `custom`) — those are
-- shadowed by the dispatcher's tree walk.
vim.cmd("Org agenda myview")
local bufnr2 = vim.api.nvim_get_current_buf()
local state2 = vim.b[bufnr2].organ_agenda
assert(
  state2 and state2.view and state2.view.blocks[1].line_format ~= fmt_global,
  "custom view's line_format should win over the global"
)
vim.api.nvim_buf_delete(bufnr2, { force = true })

-- Unknown view name surfaces as a Vim error (notify ERROR is wrapped to a
-- throw by :exe). Caller catches via pcall.
local ok, err = pcall(vim.cmd, "Org agenda nonexistent")
assert(not ok, ":Org agenda nonexistent should signal an error")
assert(err:find("no agenda view named nonexistent", 1, true), "unexpected error: " .. tostring(err))

vim.fn.delete(tmp, "rf")
io.write("agenda views ok\n")
os.exit(0)
