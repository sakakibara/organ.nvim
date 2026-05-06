-- Pure org-table renderer for clock report.

local M = {}

local function format_duration(secs)
  local minutes = math.floor(secs / 60)
  local h = math.floor(minutes / 60)
  local m = minutes - h * 60
  return string.format("%d:%02d", h, m)
end

function M.render(rows, _opts)
  local lines = {}

  -- Compute column widths.
  local title_w = #"Headline"
  local time_w = #"Time"
  local total = 0
  local row_strs = {}
  for _, r in ipairs(rows) do
    local t = format_duration(r.total_seconds or 0)
    title_w = math.max(title_w, #(r.title or ""))
    time_w = math.max(time_w, #t)
    row_strs[#row_strs + 1] = { title = r.title or "", time = t }
    total = total + (r.total_seconds or 0)
  end
  local total_str = format_duration(total)
  time_w = math.max(time_w, #total_str)

  local function row(a, b)
    return string.format("| %-" .. title_w .. "s | %-" .. time_w .. "s |", a, b)
  end
  local function sep()
    return "|" .. string.rep("-", title_w + 2) .. "|" .. string.rep("-", time_w + 2) .. "|"
  end

  lines[#lines + 1] = row("Headline", "Time")
  lines[#lines + 1] = sep()
  for _, rs in ipairs(row_strs) do
    lines[#lines + 1] = row(rs.title, rs.time)
  end
  lines[#lines + 1] = sep()
  lines[#lines + 1] = row("TOTAL", total_str)

  return lines
end

return M
