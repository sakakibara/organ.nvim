-- Period navigation for the agenda buffer: shift every block's date
-- window by whole periods, reset it to today, or replace it outright.

local M = {}

local vstate = require("organ.agenda.state")
local dates = require("organ.agenda.dates")

-- Shift every block's date window by n full periods (period = block span).
function M.shift_period(bufnr, n)
  local state = vstate.get(bufnr)
  local view = state.view or { blocks = {} }
  local query = require("organ.query")
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      local from_iso = query.parse_date(block.from)
      local to_iso = query.parse_date(block.to)
      if from_iso and to_iso then
        local delta = n * (dates.days_diff(from_iso, to_iso) + 1)
        block.from = dates.add_days(from_iso, delta)
        block.to = dates.add_days(to_iso, delta)
      end
    end
  end
  state.view = view
  vstate.set(bufnr, state)
end

-- Reset every block's window to today, preserving its prior span.
function M.reset_today(bufnr)
  local state = vstate.get(bufnr)
  local view = state.view or { blocks = {} }
  local query = require("organ.query")
  local today_iso = query.parse_date("today")
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      local from_iso = query.parse_date(block.from)
      local to_iso = query.parse_date(block.to)
      if from_iso and to_iso then
        block.from = today_iso
        block.to = dates.add_days(today_iso, dates.days_diff(from_iso, to_iso))
      end
    end
  end
  state.view = view
  vstate.set(bufnr, state)
end

-- Replace every block's window with the given (from, to) — relative or ISO.
function M.set_window(bufnr, from, to)
  local state = vstate.get(bufnr)
  local view = state.view or { blocks = {} }
  for _, block in ipairs(view.blocks) do
    if block.from and block.to then
      block.from = from
      block.to = to
    end
  end
  state.view = view
  vstate.set(bufnr, state)
end

return M
