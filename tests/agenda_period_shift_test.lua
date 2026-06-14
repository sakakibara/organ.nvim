-- agenda.shift_period / reset_today / set_window mutate the buffer's
-- view in place so refresh re-runs the underlying query against the new
-- date window.
-- Run via: nvim --headless -l tests/agenda_period_shift_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

-- OrgAgenda dispatcher prompts via vim.ui.select. Auto-pick the
-- "default" entry so we exercise the configured default_view (this
-- test sets `agenda.default_view` and asserts on its from/to).
vim.ui.select = function(choices, _opts, on_choice)
  for i, label in ipairs(choices) do
    if label:match("default$") then
      on_choice(label, i)
      return
    end
  end
  on_choice(choices[1], 1)
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/x.org"
io.open(fixture, "w"):close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  agenda = {
    default_view = {
      from = "today",
      to = "+6d",
      types = { "scheduled" },
      group_by = "none",
    },
  },
})

local agenda = require("organ.agenda")
local query = require("organ.query")

vim.cmd("Org agenda")
local bufnr = vim.api.nvim_get_current_buf()
assert(vim.bo[bufnr].filetype == "organ-agenda", "expected organ-agenda buffer")

local function block_dates()
  local s = agenda.buf_state(bufnr)
  return s.view.blocks[1].from, s.view.blocks[1].to
end

local today_iso = query.parse_date("today")
local plus6_iso = query.parse_date("+6d")

-- After open, dates are still relative strings ("today" / "+6d"). shift_period
-- pins them to ISO and offsets by one full span (7 days).
agenda.shift_period(bufnr, 1)
local from1, to1 = block_dates()
assert(from1:match("^%d%d%d%d%-%d%d%-%d%d$"), "from1 should be ISO; got " .. tostring(from1))
assert(to1:match("^%d%d%d%d%-%d%d%-%d%d$"), "to1 should be ISO; got " .. tostring(to1))
assert(from1 > today_iso, "after +1 period, from should be in the future")

-- shift_period(-1) should bring the window back to where it was.
agenda.shift_period(bufnr, -1)
local from0, to0 = block_dates()
assert(from0 == today_iso, "round-trip: from should equal today; got " .. from0)
assert(to0 == plus6_iso, "round-trip: to should equal +6d; got " .. to0)

-- reset_today restores today as the start of the period (span preserved).
agenda.shift_period(bufnr, 5) -- forward 5 weeks
agenda.reset_today(bufnr)
local from2, to2 = block_dates()
assert(from2 == today_iso, "reset: from should be today; got " .. from2)
assert(to2 == plus6_iso, "reset: to should be today+6d; got " .. to2)

-- set_window replaces the window with a new (from, to) — relative inputs OK.
agenda.set_window(bufnr, "today", "today")
local from3, to3 = block_dates()
assert(
  from3 == "today" and to3 == "today",
  "set_window keeps the strings the user passed; got from=" .. from3 .. " to=" .. to3
)

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.fn.delete(tmp, "rf")
io.write("agenda period shift ok\n")
os.exit(0)
