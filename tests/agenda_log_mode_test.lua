-- Log mode (Emacs `org-agenda-log-mode`).  When on, headlines whose
-- CLOSED date falls inside the visible agenda window appear as
-- additional rows under the day they were closed.  Toggle in-buffer
-- with `l`; configure initial state via `agenda.log_mode.on_start`.
--
-- Note: only the "closed" item is implemented today.  "clock" and
-- "state" items rely on per-event indexing not yet emitted by the
-- indexer; they're silent no-ops until that lands.
--
-- Run via: nvim --headless -l tests/agenda_log_mode_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

-- Tasks covering all three log-mode item types:
--   * scheduled-only (baseline; shows without log mode)
--   * closed inside window (item = "closed")
--   * clocked inside window (item = "clock")
--   * state-changed inside window (item = "state")
local f = io.open(org_dir .. "/tasks.org", "w")
f:write([==[
* TODO Open task
SCHEDULED: <2026-05-04 Mon>
* DONE Closed task
CLOSED: [2026-05-04 Mon 10:00]
* TODO Clocked task
:LOGBOOK:
CLOCK: [2026-05-04 Mon 09:00]--[2026-05-04 Mon 10:30] =>  1:30
:END:
* TODO State changed task
:LOGBOOK:
- State "WAIT"       from "TODO"       [2026-05-04 Mon 11:00]
:END:
* TODO Far-future task
SCHEDULED: <2027-01-01 Fri>
]==])
f:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = {
    tags_virt_align = false,
    footer = false,
    now_marker = false,
    now_override = "2026-05-04T12:00",
    log_mode = { items = { "closed", "clock", "state" }, on_start = false },
  },
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")

local function find_line(bufnr, needle)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find(needle, 1, true) then
      return i, l
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- (a) Default render: scheduled task only; CLOSED entries hidden.
-- ---------------------------------------------------------------------------
local bufnr = agenda.open({
  from = "2026-05-04",
  to = "2026-05-04",
  types = { "scheduled" },
  group_by = "day",
}, "log_test")

check("agenda includes scheduled task", find_line(bufnr, "Open task") ~= nil)
check(
  "default: closed task is hidden",
  find_line(bufnr, "Closed task") == nil,
  "Closed task appeared without log mode"
)

-- ---------------------------------------------------------------------------
-- (b) Press `l` to toggle log mode on: CLOSED task now appears.
-- ---------------------------------------------------------------------------
vim.api.nvim_set_current_buf(bufnr)
for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
  if m.lhs == "l" and m.callback then
    m.callback()
    break
  end
end

check("after l: Closed task appears", find_line(bufnr, "Closed task") ~= nil)
check("after l: scheduled task still shown", find_line(bufnr, "Open task") ~= nil)
check("after l: out-of-window task still excluded", find_line(bufnr, "Far-future task") == nil)

-- Clocked entries appear with a `Clocked: H:MM` label.
check("after l: Clocked task appears", find_line(bufnr, "Clocked task") ~= nil)
check("after l: clocked row labelled 'Clocked: 1:30'", find_line(bufnr, "Clocked: 1:30") ~= nil)

-- State-change entries appear with a `State: FROM -> TO` label.
check("after l: State changed task appears", find_line(bufnr, "State changed task") ~= nil)
check(
  "after l: state row labelled 'State: TODO -> WAIT'",
  find_line(bufnr, "State: TODO -> WAIT") ~= nil
)

-- ---------------------------------------------------------------------------
-- (c) Press `l` again to toggle off: CLOSED task disappears.
-- ---------------------------------------------------------------------------
for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
  if m.lhs == "l" and m.callback then
    m.callback()
    break
  end
end
check("after l (toggle off): Closed task hidden again", find_line(bufnr, "Closed task") == nil)

-- ---------------------------------------------------------------------------
-- (d) on_start = true: CLOSED entries shown on first open without
--     pressing `l`.
-- ---------------------------------------------------------------------------
vim.api.nvim_buf_delete(bufnr, { force = true })
require("organ").config.agenda.log_mode.on_start = true
local b2 = agenda.open({
  from = "2026-05-04",
  to = "2026-05-04",
  types = { "scheduled" },
  group_by = "day",
}, "log_test_on")
check("on_start = true: Closed task in first render", find_line(b2, "Closed task") ~= nil)

vim.api.nvim_buf_delete(b2, { force = true })
vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_log_mode_test: PASS")
