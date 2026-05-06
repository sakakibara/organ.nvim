-- Agenda buffer: empty-state hint + footer keymap reference.
-- Run via: nvim --headless -l tests/agenda_empty_state_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

-- Stub vim.ui.select: the OrgAgenda dispatcher prompts in headless. Pick
-- the entry whose label ends with "default" so we exercise the empty-
-- state of default_view (matches this test's intent).
vim.ui.select = function(choices, _opts, on_choice)
  for i, label in ipairs(choices) do
    if label:match("default$") then
      on_choice(label, i)
      return
    end
  end
  on_choice(choices[1], 1)
end

local function setup(opts)
  require("organ").config = require("organ.defaults")
  require("organ").setup(vim.tbl_deep_extend("force", {
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  }, opts or {}))
end

-- 1. With no indexed files, an empty agenda shows the "OrgScan" hint.
do
  setup()
  vim.cmd("Org agenda")
  local b = vim.api.nvim_get_current_buf()
  local body = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  assert(body:find("(empty agenda)", 1, true), "(empty agenda) marker present:\n" .. body)
  assert(body:find(":Org scan", 1, true), "OrgScan hint present:\n" .. body)
  assert(body:find("<CR> jump", 1, true), "footer keymap reference present:\n" .. body)
  vim.api.nvim_buf_delete(b, { force = true })
end

-- 2. cfg.agenda.footer = false suppresses the footer.
do
  setup({ agenda = { footer = false } })
  vim.cmd("Org agenda")
  local b = vim.api.nvim_get_current_buf()
  local body = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  assert(
    not body:find("<CR> jump", 1, true),
    "footer should be suppressed when agenda.footer = false"
  )
  assert(body:find("(empty agenda)", 1, true), "empty-state still present:\n" .. body)
  vim.api.nvim_buf_delete(b, { force = true })
end

-- 3. Pure M.render still emits 0 lines for an empty labelless block —
--    confirms the empty-state stays out of the pure renderer.
do
  setup()
  local agenda = require("organ.agenda")
  local out = agenda.render({ { block = { group_by = "day" }, rows = {} } }, { now = "2026-04-26" })
  assert(
    #out.lines == 0,
    "pure render must remain empty for labelless empty block; got " .. #out.lines
  )
end

io.write("agenda empty state ok\n")
os.exit(0)
