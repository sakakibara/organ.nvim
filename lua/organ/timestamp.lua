-- Timestamp arithmetic shared by the sorters and by
-- `:Org evaluate_time_range` (Emacs org-evaluate-time-range, C-c C-y).

local M = {}

local obuf = require("organ.buf")

-- Epoch seconds for an org timestamp string.  Out-of-range fields are
-- normalised the way `org-encode-time` normalises them, so a malformed
-- `<2026-13-45 Thu>` still yields a time rather than an error.  nil when
-- the string carries no date at all.
function M.to_seconds(s)
  local y, mo, d = tostring(s or ""):match("(%d%d%d%d)%-(%d%d?)%-(%d%d?)")
  if not y then
    return nil
  end
  local rest = tostring(s):match("%d%d%d%d%-%d%d?%-%d%d?(.*)$") or ""
  local h, mi = rest:match("(%d%d?):(%d%d)")
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h) or 0,
    min = tonumber(mi) or 0,
    sec = 0,
    isdst = nil,
  })
end

-- First `<a>--<b>` / `[a]--[b]` range on `text` (org accepts one or two
-- dashes).  Returns the two timestamp bodies plus the byte index just
-- past the range, or nil.
function M.range_in(text)
  local pat = "([<%[])([^>%]\n]+)[>%]]%-%-?([<%[])([^>%]\n]+)[>%]]"
  local s, e, _, ts1, _, ts2 = text:find(pat)
  if not s then
    return nil
  end
  return ts1, ts2, e
end

-- Emacs org-make-tdiff-string: "2 days 3 hours 5 minutes " -- only the
-- non-zero units, each pluralised, each followed by a space.
function M.tdiff_string(y, d, h, m)
  local out = {}
  local function unit(n, name)
    if n > 0 then
      out[#out + 1] = ("%d %s%s "):format(n, name, n > 1 and "s" or "")
    end
  end
  unit(y, "year")
  unit(d, "day")
  unit(h, "hour")
  unit(m, "minute")
  return table.concat(out)
end

-- Split `seconds` the way org-evaluate-time-range does.  With no
-- clock-time in either stamp the difference is rounded to whole days.
local function split_diff(seconds, havetime)
  if not havetime then
    return 0, math.floor(seconds / 86400 + 0.5), 0, 0
  end
  local d = math.floor(seconds / 86400)
  seconds = seconds % 86400
  local h = math.floor(seconds / 3600)
  seconds = seconds % 3600
  return 0, d, h, math.floor(seconds / 60)
end

-- Duration of the timestamp range on line `line` of `bufnr`.  Returns
-- `{ text = "...", inserted = "..." }` -- the echo-area phrasing and the
-- compact `[Nd ]HH:MM` form -- or nil plus a reason.
function M.evaluate_range(bufnr, line)
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
  if not text then
    return nil, "no such line"
  end
  local ts1, ts2, at = M.range_in(text)
  if not ts1 then
    return nil, "not at a timestamp range, and none found in current line"
  end
  local t1, t2 = M.to_seconds(ts1), M.to_seconds(ts2)
  if not (t1 and t2) then
    return nil, "malformed timestamp range"
  end
  local havetime = #ts1 > 15 or #ts2 > 15
  local diff = math.abs(t2 - t1)
  local y, d, h, m = split_diff(diff, havetime)
  local compact
  if d > 0 then
    compact = havetime and ("%dd %02d:%02d"):format(d, h, m) or ("%dd"):format(d)
  else
    compact = ("%02d:%02d"):format(h, m)
  end
  if t2 < t1 then
    compact = "- " .. compact
  end
  return { text = M.tdiff_string(y, d, h, m), compact = compact, at = at }
end

-- Drop a duration this command inserted earlier, so re-running it
-- replaces the value instead of appending a second one.
local function strip_previous(tail)
  for _, pat in ipairs({
    "^ *%-? *%d+y +%d+d +%d%d:%d%d",
    "^ *%-? *%d+d +%d%d:%d%d",
    "^ *%-? *%d+d",
    "^ *%-? *%d%d:%d%d",
  }) do
    local stripped, n = tail:gsub(pat, "", 1)
    if n > 0 then
      return stripped
    end
  end
  return tail
end

-- Emacs org-clock-update-time-maybe: on a closed CLOCK line, C-c C-y
-- recomputes the `=> H:MM` sum rather than reporting into the echo
-- area.  Returns the new sum, or nil when the line is not one.
function M.update_clock_sum(bufnr, line)
  local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  if not text:match("^%s*CLOCK:") then
    return nil
  end
  local ts1, ts2, at = M.range_in(text)
  if not ts1 then
    return nil
  end
  local t1, t2 = M.to_seconds(ts1), M.to_seconds(ts2)
  if not (t1 and t2) then
    return nil
  end
  local minutes = math.floor(math.abs(t2 - t1) / 60)
  local sum = ("%2d:%02d"):format(math.floor(minutes / 60), minutes % 60)
  obuf.set_lines(bufnr, line - 1, line, { text:sub(1, at) .. " => " .. sum })
  return sum
end

M.commands = {
  evaluate_time_range = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local sum = M.update_clock_sum(bufnr, line)
      if sum then
        require("organ.notify").info("clock sum: " .. vim.trim(sum))
        return
      end
      local res, why = M.evaluate_range(bufnr, line)
      if not res then
        require("organ.notify").warn(why)
        return
      end
      if not (cmd and cmd.bang) then
        require("organ.notify").info(vim.trim(res.text))
        return
      end
      local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
      local tail = strip_previous(text:sub(res.at + 1))
      obuf.set_lines(bufnr, line - 1, line, { text:sub(1, res.at) .. " " .. res.compact .. tail })
      require("organ.notify").info("time difference inserted")
    end,
    bang = true,
    desc = "Report the duration of the timestamp range on this line (Emacs C-c C-y; `!` inserts it)",
  },
}

return M
