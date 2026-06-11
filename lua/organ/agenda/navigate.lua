-- Period navigation for the agenda buffer: shift every block's date
-- window by whole periods, reset it to today, or replace it outright.
-- The date helpers here anchor at midnight, unlike agenda/dates.lua's
-- noon-anchored iso_to_ts; the two are deliberately separate.

local M = {}

local vstate = require("organ.agenda.state")

-- Convert an ISO date "YYYY-MM-DD" to a unix timestamp (UTC midnight).
local function iso_to_time(iso)
  local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })
end

local function time_to_iso(t)
  local lt = os.date("*t", t)
  return string.format("%04d-%02d-%02d", lt.year, lt.month, lt.day)
end

local function shift_iso(iso, days)
  local t = iso_to_time(iso)
  if not t then
    return iso
  end
  return time_to_iso(t + days * 86400)
end

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
        local from_t = iso_to_time(from_iso)
        local to_t = iso_to_time(to_iso)
        local span = math.floor((to_t - from_t) / 86400) + 1
        local delta = n * span
        block.from = shift_iso(from_iso, delta)
        block.to = shift_iso(to_iso, delta)
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
        local span = math.floor((iso_to_time(to_iso) - iso_to_time(from_iso)) / 86400)
        block.from = today_iso
        block.to = shift_iso(today_iso, span)
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
