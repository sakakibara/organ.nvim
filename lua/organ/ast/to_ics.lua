-- ICS (RFC 5545) renderer for organ.nvim AST.
--
-- Walks AST headlines and emits a VEVENT per SCHEDULED / DEADLINE entry
-- and per active timestamp in the entry body.  A repeater becomes an
-- RRULE, the body text a DESCRIPTION and the headline tags CATEGORIES.
-- CLOSED is informational and does not produce a VEVENT; a headline with
-- no date at all is skipped.
--
-- The output is a full VCALENDAR document.

local M = {}

local CRLF = "\r\n"

-- RFC 5545 section 3.1: fold lines longer than 75 octets at 75-octet
-- boundary, continued with CRLF + space.  Enforces boundary on bytes.
local function fold_line(line)
  if #line <= 75 then
    return line
  end
  local parts = {}
  parts[#parts + 1] = line:sub(1, 75)
  local i = 76
  while i <= #line do
    parts[#parts + 1] = " " .. line:sub(i, i + 73)
    i = i + 74
  end
  return table.concat(parts, CRLF)
end

local function escape_text(s)
  if not s then
    return ""
  end
  s = s:gsub("\\", "\\\\")
  s = s:gsub(";", "\\;")
  s = s:gsub(",", "\\,")
  s = s:gsub("\n", "\\n")
  return s
end

-- org repeater unit -> RFC 5545 frequency.
local FREQ = { h = "HOURLY", d = "DAILY", w = "WEEKLY", m = "MONTHLY", y = "YEARLY" }

-- The day after `yyyymmdd`, which is the exclusive DTEND an all-day
-- VEVENT needs.
local function next_day(date)
  local y, m, d = date:match("^(%d%d%d%d)(%d%d)(%d%d)$")
  return os.date(
    "!%Y%m%d",
    os.time({
      year = tonumber(y),
      month = tonumber(m),
      day = tonumber(d) + 1,
      hour = 12,
    })
  )
end

-- Parse "<2026-05-02 Sat>" / "<2026-05-02 Sat 14:30>" /
-- "<2026-05-02 Sat 14:30-15:00>" / "<a>--<b>", with an optional
-- `+1w` / `++1w` / `.+1w` repeater.
-- Returns { date, start_time, end_time, end_date, all_day, rrule }.
local function parse_org_ts(s)
  if not s then
    return nil
  end
  local first, second = s:match("([<%[][^>%]]+[>%]])%-%-([<%[][^>%]]+[>%]])")
  local raw = (first or s):match("[<%[]([^>%]]+)[>%]]") or s
  local y, m, d = raw:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  local out = { date = y .. m .. d }
  local n, unit = raw:match("%+%+?(%d+)([hdwmy])")
  if not n then
    n, unit = raw:match("%.%+(%d+)([hdwmy])")
  end
  if n and FREQ[unit] then
    out.rrule = "FREQ=" .. FREQ[unit] .. ";INTERVAL=" .. tonumber(n)
  end
  local function hhmm00(h, mn)
    return string.format("%02d%s00", tonumber(h), mn)
  end
  if second then
    local ey, em, ed = second:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
    local sh, smn = raw:match("(%d%d?):(%d%d)")
    local eh, emn = second:match("(%d%d?):(%d%d)")
    if ey then
      out.end_date = ey .. em .. ed
    end
    if sh then
      out.start_time = hhmm00(sh, smn)
      out.end_time = eh and hhmm00(eh, emn) or nil
    else
      out.all_day = true
    end
    return out
  end
  local h1, mn1, h2, mn2 = raw:match("(%d%d?):(%d%d)%-(%d%d?):(%d%d)")
  if h1 then
    out.start_time = hhmm00(h1, mn1)
    out.end_time = hhmm00(h2, mn2)
    return out
  end
  local h, mn = raw:match("(%d%d?):(%d%d)")
  if h then
    out.start_time = hhmm00(h, mn)
    return out
  end
  out.all_day = true
  return out
end

local function dtstamp_now()
  return os.date("!%Y%m%dT%H%M%SZ")
end

-- Flatten an inline-node array to plain text (strip emphasis markup,
-- keep link description / target).
local function inline_text(nodes)
  if not nodes then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "emphasis" then
      out[#out + 1] = inline_text(n.content)
    elseif n.kind == "radio_target" then
      out[#out + 1] = n.phrase or ""
    elseif n.kind == "link" then
      if n.form == "radio" then
        out[#out + 1] = inline_text(n.description)
      else
        if n.description and #n.description > 0 then
          out[#out + 1] = inline_text(n.description)
        else
          out[#out + 1] = n.target or ""
        end
      end
    elseif n.kind == "raw_inline" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "timestamp" or n.kind == "statistics_cookie" then
      out[#out + 1] = n.value or ""
    end
  end
  return table.concat(out)
end

-- The entry's own body text, which becomes DESCRIPTION.  Nested
-- headlines carry their own event, so they are not folded in.
local function body_text(node)
  local parts = {}
  for _, c in ipairs(node.children or {}) do
    if c.kind == "paragraph" then
      parts[#parts + 1] = inline_text(c.inline)
    end
  end
  return table.concat(parts, "\n")
end

-- Active timestamps in the entry body each produce their own VEVENT,
-- the way ox-icalendar treats a plain timestamp.
local function body_timestamps(node, into)
  for _, c in ipairs(node.children or {}) do
    if c.kind == "paragraph" then
      for _, n in ipairs(c.inline or {}) do
        if n.kind == "timestamp" and (n.variant == "active" or n.variant == "range_active") then
          into[#into + 1] = { kind = "TIMESTAMP", raw = n.value }
        end
      end
    end
  end
end

local function collect_records(ast)
  local records = {}
  local function walk(node)
    if node.kind == "headline" then
      local entries = {}
      local planning = node.planning or {}
      if planning.scheduled then
        entries[#entries + 1] = { kind = "SCHEDULED", raw = planning.scheduled }
      end
      if planning.deadline then
        entries[#entries + 1] = { kind = "DEADLINE", raw = planning.deadline }
      end
      body_timestamps(node, entries)
      if #entries > 0 then
        local id = node.properties and node.properties.ID
        records[#records + 1] = {
          title = inline_text(node.title),
          id = id,
          entries = entries,
          description = body_text(node),
          categories = node.tags,
          index = #records + 1,
        }
      end
    end
    for _, c in ipairs(node.children or {}) do
      walk(c)
    end
  end
  walk(ast)
  return records
end

-- Emit a VCALENDAR document.
function M.render(ast, _opts)
  if not ast then
    return ""
  end
  local records = collect_records(ast)
  local out = {
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//organ.nvim//ICS export//EN",
    "CALSCALE:GREGORIAN",
  }
  for _, rec in ipairs(records) do
    for _, entry in ipairs(rec.entries) do
      local ts = parse_org_ts(entry.raw)
      if ts then
        out[#out + 1] = "BEGIN:VEVENT"
        local uid = rec.id or string.format("organ-%d-%s", rec.index, entry.kind:lower())
        if rec.id and #rec.entries > 1 then
          uid = rec.id .. "-" .. entry.kind:lower()
        end
        out[#out + 1] = "UID:" .. uid
        out[#out + 1] = "DTSTAMP:" .. dtstamp_now()
        if ts.all_day then
          out[#out + 1] = "DTSTART;VALUE=DATE:" .. ts.date
          out[#out + 1] = "DTEND;VALUE=DATE:" .. next_day(ts.end_date or ts.date)
        else
          out[#out + 1] = "DTSTART:" .. ts.date .. "T" .. ts.start_time
          if ts.end_time then
            out[#out + 1] = "DTEND:" .. (ts.end_date or ts.date) .. "T" .. ts.end_time
          end
        end
        if ts.rrule then
          out[#out + 1] = "RRULE:" .. ts.rrule
        end
        local prefix = entry.kind == "DEADLINE" and "(Deadline) " or ""
        out[#out + 1] = "SUMMARY:" .. escape_text(prefix .. rec.title)
        if rec.description and rec.description ~= "" then
          out[#out + 1] = "DESCRIPTION:" .. escape_text(rec.description)
        end
        if rec.categories and #rec.categories > 0 then
          out[#out + 1] = "CATEGORIES:" .. escape_text(table.concat(rec.categories, ","))
        end
        out[#out + 1] = "END:VEVENT"
      end
    end
  end
  out[#out + 1] = "END:VCALENDAR"
  local folded = {}
  for _, l in ipairs(out) do
    folded[#folded + 1] = fold_line(l)
  end
  return table.concat(folded, CRLF) .. CRLF
end

M._parse_org_ts = parse_org_ts
M._fold_line = fold_line
M._escape_text = escape_text

return M
