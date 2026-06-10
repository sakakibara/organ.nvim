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

-- Canonical planning order. Values align under the SCHEDULED keyword,
-- whose "SCHEDULED:" is the widest at 10 columns.
local PLANNING_ORDER = { "SCHEDULED", "DEADLINE", "CLOSED" }
local PLANNING_PAD = 10

-- Render the canonical planning block: one keyword per line, in fixed
-- order, values column-aligned, prefixed with `indent`. `entries` maps
-- lower-case keyword -> timestamp string (e.g. "<...>" or "[...]").
function M.render_planning(entries, indent)
  local out = {}
  for _, kw in ipairs(PLANNING_ORDER) do
    local ts = entries[kw:lower()]
    if ts then
      out[#out + 1] = indent .. string.format("%-" .. PLANNING_PAD .. "s %s", kw .. ":", ts)
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
-- `headline_row`, honoring the `todo.planning_indent` config: a number
-- (fixed spaces), false (none), or "adapt"/default (headline level + 1).
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

return M
