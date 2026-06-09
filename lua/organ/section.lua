-- Read-only model of a headline's section: planning, property drawer,
-- LOGBOOK, and the rows where new elements belong. Thin glue over the
-- placement helpers in element.lua / drawer.lua so insertion sites and
-- the formatter share ONE notion of "where things go".

local element = require("organ.element")
local drawer = require("organ.drawer")

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

return M
