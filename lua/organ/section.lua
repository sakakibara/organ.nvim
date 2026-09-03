-- Read-only model of a headline's section: planning, property drawer,
-- LOGBOOK, and the rows where new elements belong. Thin glue over the
-- placement helpers in element.lua / drawer.lua so insertion sites and
-- the formatter share ONE notion of "where things go".

local element = require("organ.element")
local drawer = require("organ.drawer")
local obuf = require("organ.buf")

local M = {}

-- Parse the section under the headline at 0-based `headline_row` into a
-- single model. Line numbers are 1-based; `headline_row` echoes the input.
function M.parse(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local planning = element.planning_lines(bufnr, headline_row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lb_start, lb_end = drawer.find(lines, headline_row + 1, "LOGBOOK", bufnr)
  return {
    headline_row = headline_row,
    planning = planning,
    planning_end = element.planning_end_line(bufnr, headline_row),
    property_drawer = element.property_drawer_range(bufnr, headline_row),
    logbook = lb_start and { start_line = lb_start, end_line = lb_end } or nil,
  }
end

-- 1-based row where new content of `kind` belongs under the headline at
-- 0-based `headline_row`. Behavior-preserving glue over element/drawer.
function M.where(bufnr, headline_row, kind)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if kind == "property_drawer" then
    -- A fresh :PROPERTIES: drawer goes immediately after planning.
    return element.planning_end_line(bufnr, headline_row)
  elseif kind == "drawer" then
    -- A fresh named drawer goes after planning + any property drawer.
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return drawer.insert_position(lines, headline_row + 1, bufnr)
  end
  error("section.where: unknown kind " .. tostring(kind))
end

-- Keyword order of org-element-planning-interpreter.
local PLANNING_ORDER = { "DEADLINE", "SCHEDULED", "CLOSED" }

-- One planning line from ordered `{ kw, ts }` entries.
local function join_entries(list, indent)
  local parts = {}
  for _, e in ipairs(list) do
    parts[#parts + 1] = e.kw .. ": " .. e.ts
  end
  return indent .. table.concat(parts, " ")
end

-- Pull the timestamp for `kw` (e.g. "SCHEDULED") out of a planning line,
-- handling both active <...> and inactive [...] forms. nil if absent.
local function ts_on_line(line, kw)
  return line:match(kw .. ":%s*(<[^>]*>)") or line:match(kw .. ":%s*(%b[])")
end

-- Sorted, de-duplicated 1-based rows carrying planning entries.
local function planning_rows(p)
  local seen, rows = {}, {}
  for _, kw in ipairs(PLANNING_ORDER) do
    local r = p[kw:lower()]
    if r and not seen[r] then
      seen[r] = true
      rows[#rows + 1] = r
    end
  end
  table.sort(rows)
  return rows
end

-- Planning entries `{ kw, ts }` in buffer order (row, then column).
local function planning_entries(bufnr, p)
  local found = {}
  for _, kw in ipairs(PLANNING_ORDER) do
    local row = p[kw:lower()]
    if row then
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      local ts = ts_on_line(line, kw)
      if ts then
        found[#found + 1] = { kw = kw, ts = ts, row = row, col = line:find("%f[%w]" .. kw .. ":") }
      end
    end
  end
  table.sort(found, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    end
    return a.col < b.col
  end)
  return found
end

-- Section-indent string for a headline of the given `level`, honoring the
-- `todo.planning_indent` config.  This is the one indent every real-indent
-- writer uses (planning, property/logbook drawers, and -- when
-- `indent.adapt_indentation` is on -- body prose), so they all agree.
--   "adapt" (default)  level + 1 spaces (= Emacs `stars + 1`, the column
--                      where the headline title begins).
--   <number>           fixed N spaces.
--   false              flush left.
function M.section_indent_for(level, mode)
  if mode == nil then
    mode = "adapt"
  end
  if type(mode) == "number" then
    return string.rep(" ", math.max(0, mode))
  end
  if mode == "adapt" then
    return string.rep(" ", (level or 1) + 1)
  end
  return ""
end

-- Indent string for planning lines under the headline at 0-based
-- `headline_row` (reads the level from the buffer, then defers to
-- `section_indent_for`).
function M.planning_indent(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local mode = (require("organ.buf_config").read(bufnr, "todo") or {}).planning_indent
  local level = 1
  if mode == "adapt" or mode == nil then
    local line = (vim.api.nvim_buf_get_lines(bufnr, headline_row, headline_row + 1, false) or {})[1]
      or ""
    level = #(line:match("^(%*+)%s") or "*")
  end
  return M.section_indent_for(level, mode)
end

-- Set/update/clear one planning keyword under the headline at 0-based
-- `headline_row`, the way org-add-planning-info does: the keyword is
-- removed from the planning line and re-inserted at its start, the other
-- keywords keep their order, and everything ends up on one line. `kind`
-- is "SCHEDULED" | "DEADLINE" | "CLOSED"; `ts` is the timestamp string,
-- or nil to remove that keyword.
function M.set_planning(bufnr, headline_row, kind, ts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local p = M.parse(bufnr, headline_row).planning

  local entries = {}
  if ts then
    entries[1] = { kw = kind, ts = ts }
  end
  for _, e in ipairs(planning_entries(bufnr, p)) do
    if e.kw ~= kind then
      entries[#entries + 1] = e
    end
  end

  local block = {}
  if #entries > 0 then
    block[1] = join_entries(entries, M.planning_indent(bufnr, headline_row))
  end

  local rows = planning_rows(p)
  if #rows == 0 then
    obuf.set_lines(bufnr, headline_row + 1, headline_row + 1, block)
    return
  end
  for i = #rows, 2, -1 do
    obuf.set_lines(bufnr, rows[i] - 1, rows[i], {})
  end
  obuf.set_lines(bufnr, rows[1] - 1, rows[1], block)
end

-- Reorder a headline's recognized prefix elements into canonical order:
-- planning (merged onto one line) -> property drawer -> LOGBOOK. CONSERVATIVE:
-- it only rewrites a contiguous region made up ENTIRELY of recognized element
-- lines; if any other line (blank, comment, body, unknown drawer) falls inside
-- that region it ABORTS without changes, so content is never lost or mangled.
-- No-op-safe writes: canonical input neither changes nor dirties the buffer.
function M.canonicalize(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local model = M.parse(bufnr, headline_row)
  local p = model.planning

  local recognized = {}
  for _, kw in ipairs(PLANNING_ORDER) do
    local r = p[kw:lower()]
    if r then
      recognized[r] = true
    end
  end
  local pd = model.property_drawer
  if pd then
    for r = pd.start_line, pd.end_line do
      recognized[r] = true
    end
  end
  local lb = model.logbook
  if lb then
    for r = lb.start_line, lb.end_line do
      recognized[r] = true
    end
  end

  local rows = {}
  for r in pairs(recognized) do
    rows[#rows + 1] = r
  end
  if #rows == 0 then
    return
  end
  table.sort(rows)
  local lo, hi = rows[1], rows[#rows]

  for r = lo, hi do
    if not recognized[r] then
      return
    end
  end

  local indent = M.planning_indent(bufnr, headline_row)
  local block = {}
  local entries = planning_entries(bufnr, p)
  if #entries > 0 then
    block[1] = join_entries(entries, indent)
  end
  if pd then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, pd.start_line - 1, pd.end_line, false)) do
      block[#block + 1] = indent .. l:gsub("^%s*", "")
    end
  end
  if lb then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, lb.start_line - 1, lb.end_line, false)) do
      block[#block + 1] = indent .. l:gsub("^%s*", "")
    end
  end

  obuf.set_lines(bufnr, lo - 1, hi, block)
end

return M
