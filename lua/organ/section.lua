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

-- Canonical planning order.
local PLANNING_ORDER = { "SCHEDULED", "DEADLINE", "CLOSED" }

-- Render the canonical planning block: one keyword per line, in fixed
-- order, exactly one space after the colon (Emacs form, matching the
-- to_org exporter), prefixed with `indent`. `entries` maps lower-case
-- keyword -> timestamp string (e.g. "<...>" or "[...]").
function M.render_planning(entries, indent)
  local out = {}
  for _, kw in ipairs(PLANNING_ORDER) do
    local ts = entries[kw:lower()]
    if ts then
      out[#out + 1] = indent .. kw .. ": " .. ts
    end
  end
  return out
end

-- Pull the timestamp for `kw` (e.g. "SCHEDULED") out of a planning line,
-- handling both active <...> and inactive [...] forms. nil if absent.
local function ts_on_line(line, kw)
  return line:match(kw .. ":%s*(<[^>]*>)") or line:match(kw .. ":%s*(%b[])")
end

-- Indent string for planning lines under the headline at 0-based
-- `headline_row`, honoring the `todo.planning_indent` config:
--   "adapt" (default)  headline level + 1 spaces -- matches Emacs
--                      `org-adapt-indentation = 'headline-data'`, the
--                      Org 9.5+ / Emacs 30.x default.
--   <number>           fixed N spaces (pre-9.5 convention is usually 2).
--   0 / false          flush left (`org-adapt-indentation = nil`).
function M.planning_indent(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cfg = require("organ.buf_config").read(bufnr, "todo") or {}
  local mode = cfg.planning_indent
  if mode == nil then
    mode = "adapt"
  end
  if type(mode) == "number" then
    return string.rep(" ", math.max(0, mode))
  end
  if mode == false then
    return ""
  end
  if mode == "adapt" then
    local line = (vim.api.nvim_buf_get_lines(bufnr, headline_row, headline_row + 1, false) or {})[1]
      or ""
    local stars = line:match("^(%*+)%s")
    local level = stars and #stars or 1
    return string.rep(" ", level + 1)
  end
  return ""
end

-- Set/update/clear one planning keyword under the headline at 0-based
-- `headline_row`, then rewrite the whole planning block in canonical form.
-- `kind` is "SCHEDULED" | "DEADLINE" | "CLOSED"; `ts` is the timestamp
-- string, or nil to remove that keyword.
function M.set_planning(bufnr, headline_row, kind, ts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local model = M.parse(bufnr, headline_row)
  local p = model.planning

  local entries = {}
  for _, kw in ipairs(PLANNING_ORDER) do
    local row = p[kw:lower()]
    if row then
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      entries[kw:lower()] = ts_on_line(line, kw)
    end
  end
  entries[kind:lower()] = ts

  local indent = M.planning_indent(bufnr, headline_row)

  local block = M.render_planning(entries, indent)

  local rows = {}
  for _, kw in ipairs(PLANNING_ORDER) do
    if p[kw:lower()] then
      rows[#rows + 1] = p[kw:lower()]
    end
  end
  if #rows > 0 then
    local lo, hi = rows[1], rows[1]
    for _, r in ipairs(rows) do
      lo, hi = math.min(lo, r), math.max(hi, r)
    end
    obuf.set_lines(bufnr, lo - 1, hi, block)
  else
    obuf.set_lines(bufnr, headline_row + 1, headline_row + 1, block)
  end
end

-- Reorder a headline's recognized prefix elements into canonical order:
-- planning (re-rendered canonical) -> property drawer -> LOGBOOK. CONSERVATIVE:
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

  local entries = {}
  for _, kw in ipairs(PLANNING_ORDER) do
    local r = p[kw:lower()]
    if r then
      local line = vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false)[1] or ""
      entries[kw:lower()] = ts_on_line(line, kw)
    end
  end
  local block = M.render_planning(entries, M.planning_indent(bufnr, headline_row))
  if pd then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, pd.start_line - 1, pd.end_line, false)) do
      block[#block + 1] = l
    end
  end
  if lb then
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, lb.start_line - 1, lb.end_line, false)) do
      block[#block + 1] = l
    end
  end

  obuf.set_lines(bufnr, lo - 1, hi, block)
end

return M
