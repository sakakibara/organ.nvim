-- ICS (RFC 5545) renderer for organ.nvim AST.
--
-- Walks AST headlines, finds those with planning (SCHEDULED / DEADLINE),
-- emits a VEVENT per planning timestamp.  Headlines without planning are
-- silently skipped (ICS is event-only).  CLOSED is informational and does
-- not produce a VEVENT.
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
  local parts, i = {}, 1
  parts[#parts + 1] = line:sub(1, 75)
  i = 76
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

-- Parse "<2026-05-02 Sat>" / "<2026-05-02 Sat 14:30>" / "<2026-05-02 Sat 14:30-15:00>".
-- Returns { date = "20260502", start_time, end_time, all_day }.
local function parse_org_ts(s)
  if not s then
    return nil
  end
  local raw = s:match("[<%[]([^>%]]+)[>%]]") or s
  local y, m, d = raw:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  local out = { date = y .. m .. d }
  local h1, mn1, h2, mn2 = raw:match("(%d%d):(%d%d)%-(%d%d):(%d%d)")
  if h1 then
    out.start_time = h1 .. mn1 .. "00"
    out.end_time = h2 .. mn2 .. "00"
    return out
  end
  local h, mn = raw:match("(%d%d):(%d%d)")
  if h then
    out.start_time = h .. mn .. "00"
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
      if n.description and #n.description > 0 then
        out[#out + 1] = inline_text(n.description)
      else
        out[#out + 1] = n.target or ""
      end
    elseif n.kind == "raw_inline" then
      out[#out + 1] = n.text or ""
    end
  end
  return table.concat(out)
end

-- Walk AST collecting eligible records.  One record per headline with
-- planning; each record carries the set of SCHEDULED/DEADLINE entries
-- that should produce a VEVENT.
local function collect_records(ast)
  local records = {}
  local function walk(node)
    if node.kind == "headline" and node.planning then
      local entries = {}
      if node.planning.scheduled then
        entries[#entries + 1] = { kind = "SCHEDULED", raw = node.planning.scheduled }
      end
      if node.planning.deadline then
        entries[#entries + 1] = { kind = "DEADLINE", raw = node.planning.deadline }
      end
      if #entries > 0 then
        local id = node.properties and node.properties.ID
        records[#records + 1] = {
          title = inline_text(node.title),
          id = id,
          entries = entries,
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
        out[#out + 1] = "UID:" .. uid
        out[#out + 1] = "DTSTAMP:" .. dtstamp_now()
        if ts.all_day then
          out[#out + 1] = "DTSTART;VALUE=DATE:" .. ts.date
        else
          out[#out + 1] = "DTSTART:" .. ts.date .. "T" .. ts.start_time
          if ts.end_time then
            out[#out + 1] = "DTEND:" .. ts.date .. "T" .. ts.end_time
          end
        end
        local prefix = entry.kind == "DEADLINE" and "(Deadline) " or ""
        out[#out + 1] = "SUMMARY:" .. escape_text(prefix .. rec.title)
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
