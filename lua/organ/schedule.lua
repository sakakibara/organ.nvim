-- lua/organ/schedule.lua
-- :Org schedule and :Org deadline — set/update planning timestamps.
-- Matches Emacs C-c C-s / C-c C-d.

local M = {}

-- Build an org active timestamp string from an ISO date and optional
-- time_info ({ start = "HH:MM", finish = "HH:MM"? } or nil):
--   nil                       -> <YYYY-MM-DD Day>
--   { start }                 -> <YYYY-MM-DD Day HH:MM>
--   { start, finish }         -> <YYYY-MM-DD Day HH:MM-HH:MM>
local function format_active_ts(iso, time_info)
  local y, mo, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
  local wd = os.date("%a", t) -- Mon / Tue / Wed …
  local time_str = ""
  if time_info and time_info.start then
    time_str = " " .. time_info.start
    if time_info.finish then
      time_str = time_str .. "-" .. time_info.finish
    end
  end
  return string.format("<%s %s%s>", iso, wd, time_str)
end

-- Extract the existing <…> timestamp string for `kind` from a planning line,
-- or nil if absent. Used by the LOGBOOK reschedule hook.
local function existing_ts(line, kind)
  return line:match(kind .. ":%s*(<[^>]*>)")
end

-- Parse the time component of an org timestamp string into a prefill
-- table { start = "HH:MM", finish = "HH:MM"? } or nil (date-only).
local function parse_ts_time(ts)
  if not ts then
    return nil
  end
  local s, e = ts:match("(%d%d?:%d%d)%-(%d%d?:%d%d)>")
  if s then
    return { start = s, finish = e }
  end
  local single = ts:match(" (%d%d?:%d%d)>")
  if single then
    return { start = single }
  end
  return nil
end
M._parse_ts_time = parse_ts_time

-- Repeater / warning cookie of a timestamp (`+1w`, `.+1d/3d`, `++1w -2d`,
-- `-2d`), matched the way Emacs `org--deadline-or-schedule` does.
local function planning_cookie(ts)
  if not ts then
    return nil
  end
  local s, e = ts:find("[%.%+%-]+%d+[hdwmy]")
  if not s then
    return nil
  end
  local _, e2 = ts:find("^[/ ][%-%+]?%d+[hdwmy]", e + 1)
  return ts:sub(s, e2 or e)
end

-- Insert or update a SCHEDULED/DEADLINE keyword on the planning line and
-- drop CLOSED, as Emacs `org--deadline-or-schedule` does.
-- kind    = "SCHEDULED" | "DEADLINE"
-- date_str = iso string "YYYY-MM-DD"
local function _set_planning(bufnr, hl_line, kind, date_str, time_info)
  local ts = format_active_ts(date_str, time_info)
  if not ts then
    require("organ.notify").error("organ: invalid date: " .. tostring(date_str))
    return
  end

  local cfg = (require("organ.buf_config").read(nil, "todo") or {})
  local policy_key = kind == "DEADLINE" and "log_redeadline" or "log_reschedule"
  local policy = cfg[policy_key]
  local verb = kind == "DEADLINE" and "New deadline" or "Rescheduled"

  -- Snapshot the previous value for the optional LOGBOOK note.
  local pl_lines = require("organ.element").planning_lines(bufnr, hl_line - 1)
  local old_ts
  do
    local row = pl_lines[kind:lower()]
    if row then
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      old_ts = existing_ts(line, kind)
    end
  end

  local cookie = planning_cookie(old_ts)
  if cookie then
    ts = ts:sub(1, -2) .. " " .. cookie .. ">"
  end

  local section = require("organ.section")
  section.set_planning(bufnr, hl_line - 1, kind, ts)
  section.set_planning(bufnr, hl_line - 1, "CLOSED", nil)

  -- LOGBOOK note (only for true CHANGES; first-time schedule with no prior
  -- value bypasses the log to avoid noise — Emacs parity).
  if old_ts and (policy == "time" or policy == "note") then
    require("organ.logbook").write_planning_change(bufnr, hl_line, policy, verb, old_ts)
  end
end

-- Public: set SCHEDULED timestamp via calendar picker.  `opts.bufnr` and
-- `opts.line` default to the current buffer + cursor line.
function M.set_schedule(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local structure = require("organ.structure")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    require("organ.notify").warn("not on a headline")
    return
  end
  local prefill
  do
    local pl_lines = require("organ.element").planning_lines(bufnr, hl.line - 1)
    local row = pl_lines.scheduled
    if row then
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      prefill = parse_ts_time(existing_ts(line, "SCHEDULED"))
    end
  end
  require("organ.calendar").pick(
    { title = "Schedule", time = true, prefill_time = prefill },
    function(iso, time_info)
      if not iso then
        return
      end
      _set_planning(bufnr, hl.line, "SCHEDULED", iso, time_info)
    end
  )
end

-- Public: set DEADLINE timestamp via calendar picker.  `opts.bufnr` and
-- `opts.line` default to the current buffer + cursor line.
function M.set_deadline(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local structure = require("organ.structure")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    require("organ.notify").warn("not on a headline")
    return
  end
  local prefill
  do
    local pl_lines = require("organ.element").planning_lines(bufnr, hl.line - 1)
    local row = pl_lines.deadline
    if row then
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      prefill = parse_ts_time(existing_ts(line, "DEADLINE"))
    end
  end
  require("organ.calendar").pick(
    { title = "Deadline", time = true, prefill_time = prefill },
    function(iso, time_info)
      if not iso then
        return
      end
      _set_planning(bufnr, hl.line, "DEADLINE", iso, time_info)
    end
  )
end

-- Expose helper for tests.
M._set_planning = _set_planning
M._format_active_ts = format_active_ts

M.commands = {
  schedule = {
    fn = function()
      M.set_schedule()
    end,
    desc = "Set/update SCHEDULED: timestamp on the headline at cursor (Emacs C-c C-s)",
  },
  deadline = {
    fn = function()
      M.set_deadline()
    end,
    desc = "Set/update DEADLINE: timestamp on the headline at cursor (Emacs C-c C-d)",
  },
}

return M
