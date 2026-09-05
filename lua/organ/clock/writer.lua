-- CLOCK line writer/closer/canceller. Reuses lua/organ/drawer.lua.

local drawer = require("organ.drawer")

local M = {}

local obuf = require("organ.buf")
local function ts_inactive(t)
  return os.date("[%Y-%m-%d %a %H:%M]", t)
end

-- Emacs writes the duration with `(format "%2d:%02d" h m)`, so a
-- single-digit hour is padded to two columns.
local function format_duration(secs)
  local minutes = math.floor(secs / 60)
  local h = math.floor(minutes / 60)
  local m = minutes - h * 60
  return string.format("%2d:%02d", h, m)
end

-- Indent every CLOCK/LOGBOOK line the way the planning and property writers
-- indent theirs, so one entry cannot end up with drawers at three columns.
local function indent_of(bufnr, hl_line)
  return require("organ.section").planning_indent(bufnr, hl_line - 1)
end

function M.write_active(bufnr, hl_line, drawer_name, start_ts)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local indent = indent_of(bufnr, hl_line)
  local s, _ = drawer.find(lines, hl_line, drawer_name, bufnr)
  if s then
    local lead = (lines[s] or ""):match("^([ \t]*)") or indent
    obuf.set_lines(bufnr, s, s, { lead .. "CLOCK: " .. ts_inactive(start_ts) })
  else
    local pos = drawer.insert_position(lines, hl_line, bufnr)
    obuf.set_lines(bufnr, pos - 1, pos - 1, {
      indent .. ":" .. drawer_name .. ":",
      indent .. "CLOCK: " .. ts_inactive(start_ts),
      indent .. ":END:",
    })
  end
end

-- Find the open-ended CLOCK line in the drawer for hl_line. Returns the
-- 1-based line index or nil. Active line shape:
--   "  CLOCK: [YYYY-MM-DD Day HH:MM]"   (no -- end)
local function find_active_line(buf_lines, drawer_start, drawer_end)
  for i = drawer_start + 1, drawer_end - 1 do
    local l = buf_lines[i]
    if l and l:match("^%s*CLOCK:%s*%[[^%]]+%]%s*$") then
      return i
    end
  end
  return nil
end

function M.close_active(bufnr, hl_line, drawer_name, end_ts)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s, e = drawer.find(lines, hl_line, drawer_name, bufnr)
  if not s then
    return false
  end
  local active = find_active_line(lines, s, e)
  if not active then
    return false
  end

  local original = lines[active]
  local y, mo, d, hh, mm = original:match("%[(%d+)%-(%d+)%-(%d+)[^%]]*%s+(%d+):(%d+)%]")
  if not y then
    return false
  end
  local start_ts = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(hh),
    min = tonumber(mm),
    sec = 0,
  })
  local duration = end_ts - start_ts
  local closed = string.format(
    "%sCLOCK: %s--%s => %s",
    original:match("^([ \t]*)") or "",
    ts_inactive(start_ts),
    ts_inactive(end_ts),
    format_duration(duration)
  )
  obuf.set_lines(bufnr, active - 1, active, { closed })
  return true
end

function M.cancel_active(bufnr, hl_line, drawer_name)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s, e = drawer.find(lines, hl_line, drawer_name, bufnr)
  if not s then
    return false
  end
  local active = find_active_line(lines, s, e)
  if not active then
    return false
  end
  obuf.set_lines(bufnr, active - 1, active, {})
  return true
end

return M
