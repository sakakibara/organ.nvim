-- CSV / TSV import + export for org tables.
--
-- :Org table import <path>   reads a CSV/TSV file, inserts the rows as an
--                          aligned org table at cursor.
-- :Org table export <path>   writes the org table at cursor as CSV/TSV.
--
-- Delimiter is inferred from the file extension (.csv → comma, .tsv → tab)
-- with a fallback sniff on the first line. Quoted fields (RFC 4180-ish)
-- are recognized: a field wrapped in `"..."` may contain commas, doubled
-- quotes (`""` → `"`), and embedded newlines.

local M = {}

-- ---------------------------------------------------------------------------
-- CSV parser. Streams over `text`, returns list of rows where each row is a
-- list of cell strings. Tolerates CRLF, trailing newline.
function M.parse_csv(text, delim)
  delim = delim or ","
  local rows, row, field = {}, {}, {}
  local i, n = 1, #text
  local in_quote = false
  while i <= n do
    local c = text:sub(i, i)
    if in_quote then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 2
        else
          in_quote = false
          i = i + 1
        end
      else
        field[#field + 1] = c
        i = i + 1
      end
    else
      if c == '"' then
        in_quote = true
        i = i + 1
      elseif c == delim then
        row[#row + 1] = table.concat(field)
        field = {}
        i = i + 1
      elseif c == "\n" or c == "\r" then
        row[#row + 1] = table.concat(field)
        field = {}
        rows[#rows + 1] = row
        row = {}
        if c == "\r" and text:sub(i + 1, i + 1) == "\n" then
          i = i + 2
        else
          i = i + 1
        end
      else
        field[#field + 1] = c
        i = i + 1
      end
    end
  end
  if #field > 0 or #row > 0 then
    row[#row + 1] = table.concat(field)
    rows[#rows + 1] = row
  end
  -- Drop a trailing empty row produced by a final newline.
  if rows[#rows] and #rows[#rows] == 1 and rows[#rows][1] == "" then
    rows[#rows] = nil
  end
  return rows
end

-- Detect delimiter from extension; otherwise sniff line 1.
function M.detect_delim(path, text)
  if path:lower():match("%.tsv$") then
    return "\t"
  end
  if path:lower():match("%.csv$") then
    return ","
  end
  if text then
    local first = text:match("^[^\n]+") or ""
    local n_tab, n_comma = 0, 0
    for _ in first:gmatch("\t") do
      n_tab = n_tab + 1
    end
    for _ in first:gmatch(",") do
      n_comma = n_comma + 1
    end
    if n_tab > n_comma then
      return "\t"
    end
  end
  return ","
end

-- ---------------------------------------------------------------------------
-- CSV emitter. Each row is a list of cells. Cells containing the delimiter,
-- a quote, or a newline get quoted.
function M.emit_csv(rows, delim)
  delim = delim or ","
  local out = {}
  for _, row in ipairs(rows) do
    local cells = {}
    for _, cell in ipairs(row) do
      cell = tostring(cell or "")
      if cell:find("[" .. delim:gsub("\t", "\t") .. '\n"\t]') then
        cell = '"' .. cell:gsub('"', '""') .. '"'
      end
      cells[#cells + 1] = cell
    end
    out[#out + 1] = table.concat(cells, delim)
  end
  return table.concat(out, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- Org-table → list-of-rows.
local function lstrip(s)
  return s:gsub("^%s+", "")
end

function M.parse_org_table(buf_lines, lnum)
  -- Walk up to find the start of the table block, then forward to the end.
  local function is_table_line(s)
    return (s or ""):match("^%s*|") ~= nil
  end
  if not is_table_line(buf_lines[lnum]) then
    return nil
  end
  local s = lnum
  while s > 1 and is_table_line(buf_lines[s - 1]) do
    s = s - 1
  end
  local e = lnum
  while e < #buf_lines and is_table_line(buf_lines[e + 1]) do
    e = e + 1
  end
  local rows = {}
  for i = s, e do
    local ln = buf_lines[i] or ""
    if not ln:match("^%s*|%-") then -- skip divider rows
      local cells = {}
      for c in ln:gmatch("|([^|]*)") do
        cells[#cells + 1] = lstrip(c):gsub("%s+$", "")
      end
      while #cells > 0 and cells[#cells] == "" do
        cells[#cells] = nil
      end
      if #cells > 0 then
        rows[#rows + 1] = cells
      end
    end
  end
  return rows, s, e
end

-- ---------------------------------------------------------------------------
-- Render rows as an aligned org table (single divider after the header).
function M.render_org_table(rows)
  if #rows == 0 then
    return {}
  end
  local ncols = 0
  for _, r in ipairs(rows) do
    if #r > ncols then
      ncols = #r
    end
  end
  local widths = {}
  for c = 1, ncols do
    widths[c] = 0
  end
  for _, r in ipairs(rows) do
    for c = 1, ncols do
      local cell = r[c] or ""
      local w = vim.fn.strdisplaywidth(cell)
      if w > widths[c] then
        widths[c] = w
      end
    end
  end
  local function row(cells)
    local parts = {}
    for c = 1, ncols do
      local cell = cells[c] or ""
      parts[c] = " " .. cell .. string.rep(" ", widths[c] - vim.fn.strdisplaywidth(cell)) .. " "
    end
    return "|" .. table.concat(parts, "|") .. "|"
  end
  local function divider()
    local parts = {}
    for c = 1, ncols do
      parts[c] = string.rep("-", widths[c] + 2)
    end
    return "|" .. table.concat(parts, "+") .. "|"
  end
  local out = { row(rows[1]), divider() }
  for i = 2, #rows do
    out[#out + 1] = row(rows[i])
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Public commands.

function M.import(bufnr, lnum, path)
  bufnr = bufnr or 0
  lnum = lnum or vim.fn.line(".")
  local fd, err = io.open(path, "r")
  if not fd then
    return nil, "cannot open " .. path .. ": " .. tostring(err)
  end
  local body = fd:read("*a")
  fd:close()
  local delim = M.detect_delim(path, body)
  local rows = M.parse_csv(body, delim)
  if #rows == 0 then
    return nil, "no rows parsed"
  end
  local org_lines = M.render_org_table(rows)
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum - 1, false, org_lines)
  return #rows
end

function M.export(bufnr, lnum, path)
  bufnr = bufnr or 0
  lnum = lnum or vim.fn.line(".")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local rows = M.parse_org_table(lines, lnum)
  if not rows then
    return nil, "no org table at cursor"
  end
  local delim = M.detect_delim(path, nil)
  local body = M.emit_csv(rows, delim)
  local ok, werr = require("organ.path").write_atomic(path, body)
  if not ok then
    return nil, "cannot write " .. path .. ": " .. tostring(werr)
  end
  return #rows
end

return M
