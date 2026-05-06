-- ICS (RFC 5545) export for org buffers.
--
-- Emits one VEVENT per SCHEDULED / DEADLINE timestamp on a headline.
-- All-day events when no time-of-day is present; timed events otherwise.
-- Headline title becomes SUMMARY; the headline's :ID: (if any) becomes UID.
--
-- Scope: current buffer's headlines. To export an entire org_dir, call
-- M.export_query with {} to walk the indexed corpus.

local M = {}

local CRLF = "\r\n"

local function fold_line(line)
  -- RFC 5545 section 3.1: fold lines longer than 75 octets at 75-octet boundary,
  -- continued with CRLF + space. We just enforce the boundary on bytes.
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

local function clean_summary(line, todo_keywords)
  line = line:gsub("^%*+%s+", "")
  for _, kw in ipairs(todo_keywords or {}) do
    if kw ~= "|" then
      local pat = "^" .. kw .. "%s+"
      if line:match(pat) then
        line = line:gsub(pat, "")
        break
      end
    end
  end
  line = line:gsub("^%[#%w%]%s*", "")
  line = line:gsub("%s+:[%w_:@]+:%s*$", "")
  return line
end

-- Parse "<2026-05-02 Sat>" / "<2026-05-02 Sat 14:30>" / "<2026-05-02 Sat 14:30-15:00>"
-- Returns { date = "20260502", start_time, end_time, all_day }
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

-- Walk the buffer, collecting { headline_line, title, id, planning = {...}}.
-- planning is a list of { kind = "SCHEDULED"|"DEADLINE", ts = parsed }.
local function scan_buffer(bufnr, todo_keywords)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {}
  local cur
  for i, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      if cur and #cur.planning > 0 then
        out[#out + 1] = cur
      end
      cur = { line = i, title = clean_summary(ln, todo_keywords), id = nil, planning = {} }
    elseif cur then
      local sched = ln:match("^%s*SCHEDULED:%s*(<[^>]+>)")
      local dead = ln:match("^%s*DEADLINE:%s*(<[^>]+>)")
      local id_v = ln:match("^%s*:ID:%s*(%S+)")
      if sched then
        local ts = parse_org_ts(sched)
        if ts then
          cur.planning[#cur.planning + 1] = { kind = "SCHEDULED", ts = ts }
        end
      end
      if dead then
        local ts = parse_org_ts(dead)
        if ts then
          cur.planning[#cur.planning + 1] = { kind = "DEADLINE", ts = ts }
        end
      end
      if id_v then
        cur.id = id_v
      end
    end
  end
  if cur and #cur.planning > 0 then
    out[#out + 1] = cur
  end
  return out
end

local function dtstamp_now()
  return os.date("!%Y%m%dT%H%M%SZ")
end

local function event_lines(rec, planning)
  local lines = {}
  lines[#lines + 1] = "BEGIN:VEVENT"
  lines[#lines + 1] = "UID:"
    .. (rec.id or string.format("organ-%d-%s", rec.line, planning.kind:lower()))
  lines[#lines + 1] = "DTSTAMP:" .. dtstamp_now()
  if planning.ts.all_day then
    lines[#lines + 1] = "DTSTART;VALUE=DATE:" .. planning.ts.date
  else
    lines[#lines + 1] = "DTSTART:" .. planning.ts.date .. "T" .. planning.ts.start_time
    if planning.ts.end_time then
      lines[#lines + 1] = "DTEND:" .. planning.ts.date .. "T" .. planning.ts.end_time
    end
  end
  local prefix = planning.kind == "DEADLINE" and "(Deadline) " or ""
  lines[#lines + 1] = "SUMMARY:" .. escape_text(prefix .. rec.title)
  lines[#lines + 1] = "END:VEVENT"
  return lines
end

function M.export(src, opts)
  opts = opts or {}
  local lines
  if type(src) == "string" then
    lines = vim.split(src, "\n", { plain = true })
  else
    lines = src
  end
  -- We need a real buffer for scan_buffer; spin a scratch one.
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local todo_kw = opts.todo_keywords
    or (require("organ").config.todo and require("organ").config.todo.sequence)
    or { "TODO", "|", "DONE" }
  local recs = scan_buffer(b, todo_kw)
  pcall(vim.api.nvim_buf_delete, b, { force = true })

  local out = {
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//organ.nvim//organ-export//EN",
    "CALSCALE:GREGORIAN",
  }
  for _, rec in ipairs(recs) do
    for _, planning in ipairs(rec.planning) do
      for _, l in ipairs(event_lines(rec, planning)) do
        out[#out + 1] = fold_line(l)
      end
    end
  end
  out[#out + 1] = "END:VCALENDAR"
  return table.concat(out, CRLF) .. CRLF
end

function M.export_buffer(bufnr, opts)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.export(lines, opts)
end

function M.export_buffer_to_file(bufnr, path, opts)
  bufnr = bufnr or 0
  if not path or path == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return nil, "no buffer name; specify a path"
    end
    path = name:gsub("%.org$", "") .. ".ics"
  end
  local out = M.export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(path, out)
  if not ok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
end

-- Export every SCHEDULED/DEADLINE in the indexed corpus to a single .ics.
-- Uses the DB; doesn't touch buffers.
function M.export_query(filter, path)
  local rows = require("organ.query").agenda(
    vim.tbl_extend("force", { types = { "scheduled", "deadline" } }, filter or {})
  )
  local out = {
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//organ.nvim//organ-export//EN",
    "CALSCALE:GREGORIAN",
  }
  for _, r in ipairs(rows) do
    -- Re-derive a planning record per timestamp present on the row.
    if r.scheduled_date then
      local ts = parse_org_ts(r.scheduled or "<" .. r.scheduled_date .. ">")
      if ts then
        local rec = { id = r.id, line = r.line_start or 0, title = r.title or "" }
        for _, l in ipairs(event_lines(rec, { kind = "SCHEDULED", ts = ts })) do
          out[#out + 1] = fold_line(l)
        end
      end
    end
    if r.deadline_date then
      local ts = parse_org_ts(r.deadline or "<" .. r.deadline_date .. ">")
      if ts then
        local rec = { id = r.id, line = r.line_start or 0, title = r.title or "" }
        for _, l in ipairs(event_lines(rec, { kind = "DEADLINE", ts = ts })) do
          out[#out + 1] = fold_line(l)
        end
      end
    end
  end
  out[#out + 1] = "END:VCALENDAR"
  local body = table.concat(out, CRLF) .. CRLF
  if path then
    local ok, werr = require("organ.path").write_atomic(path, body)
    if not ok then
      return nil, werr
    end
    return path
  end
  return body
end

M._parse_org_ts = parse_org_ts
M._fold_line = fold_line
M._escape_text = escape_text

return M
