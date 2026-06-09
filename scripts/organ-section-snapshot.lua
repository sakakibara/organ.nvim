-- Apply the OPS.md op matrix to each seed via organ's non-interactive
-- primitives and print the resulting file text. Counterpart to
-- scripts/emacs-section-snapshot.el; diffed by `make parity-section`.
--
-- Usage:
--   nvim --headless -l scripts/organ-section-snapshot.lua <seed-dir>

local args = arg or {}
local seed_dir = args[1]
if not seed_dir then
  io.stderr:write("usage: organ-section-snapshot.lua <seed-dir>\n")
  os.exit(2)
end

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/tests/deps/tablature.nvim")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  org_dir = seed_dir,
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = {
    sequence = { "TODO", "|", "DONE" },
    -- log_done = "time" (default): inserts CLOSED on active->done.
    -- log_into_drawer = true (default): state-change notes go into LOGBOOK.
    -- log_state_changes = false (default): no logbook entry for plain
    -- state transitions (only CLOSED line is written).  No per-keyword
    -- annotation overrides in the sequence above, so organ writes
    -- CLOSED but no LOGBOOK state-change note.  Faithfully snapshotted.
  },
})

local PINNED_IN = os.time({ year = 2026, month = 5, day = 4, hour = 12, min = 0, sec = 0 })
local PINNED_OUT = os.time({ year = 2026, month = 5, day = 4, hour = 13, min = 30, sec = 0 })

local real_time = os.time
local real_date = os.date
os.time = function(t)
  if t ~= nil then
    return real_time(t)
  end
  return PINNED_IN
end
os.date = function(fmt, t)
  return real_date(fmt, t == nil and PINNED_IN or t)
end

local todo = require("organ.todo")
local schedule = require("organ.schedule")
local property = require("organ.property")
local clock_writer = require("organ.clock.writer")

local function open_copy(seed_path)
  local tmp = vim.fn.tempname() .. ".org"
  local lines = vim.fn.readfile(seed_path)
  vim.fn.writefile(lines, tmp)
  vim.cmd("edit " .. vim.fn.fnameescape(tmp))
  return vim.api.nvim_get_current_buf(), tmp
end

-- Headline is on line 1 in every seed. All primitives expect a 1-based
-- line number:
--   todo.set(bufnr, line, state)        -> _apply -> find_headline uses 1-based
--   schedule._set_planning(bufnr, hl_line, ...) -> buf_get_lines with hl_line as 1-based
--   property.set(bufnr, line, key, value) -> find_headline(bufnr, line) 1-based
--   clock_writer.write_active/close_active(bufnr, hl_line, ...) -> drawer.find(_, hl_line, _) 1-based
local HL = 1

local function apply(name, bufnr)
  if name == "01-close.org" then
    todo.set(bufnr, HL, "DONE")
  elseif name == "02-plan.org" then
    schedule._set_planning(bufnr, HL, "SCHEDULED", "2026-05-06", nil)
    schedule._set_planning(bufnr, HL, "DEADLINE", "2026-05-07", nil)
    todo.set(bufnr, HL, "DONE")
  elseif name == "03-prop-then-plan.org" then
    schedule._set_planning(bufnr, HL, "SCHEDULED", "2026-05-06", nil)
  elseif name == "04-logbook.org" then
    todo.set(bufnr, HL, "DONE")
    clock_writer.write_active(bufnr, HL, "LOGBOOK", PINNED_IN)
    clock_writer.close_active(bufnr, HL, "LOGBOOK", PINNED_OUT)
  elseif name == "05-full.org" then
    schedule._set_planning(bufnr, HL, "SCHEDULED", "2026-05-06", nil)
    schedule._set_planning(bufnr, HL, "DEADLINE", "2026-05-07", nil)
    property.set(bufnr, HL, "FOO", "bar")
    todo.set(bufnr, HL, "DONE")
    clock_writer.write_active(bufnr, HL, "LOGBOOK", PINNED_IN)
    clock_writer.close_active(bufnr, HL, "LOGBOOK", PINNED_OUT)
  end
end

local function dump(path)
  for _, l in ipairs(vim.fn.readfile(path)) do
    io.write(l, "\n")
  end
end

local seeds = vim.fn.glob(seed_dir .. "/*.org", false, true)
table.sort(seeds)
for _, seed in ipairs(seeds) do
  local name = vim.fn.fnamemodify(seed, ":t")
  local bufnr, tmp = open_copy(seed)
  apply(name, bufnr)
  vim.cmd("silent write")
  io.write("==> " .. name .. "\n")
  dump(tmp)
  io.write("\n")
  vim.fn.delete(tmp)
end
