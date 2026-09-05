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

local PLANNING_KEYWORDS = { "DEADLINE", "SCHEDULED", "CLOSED" }

-- Span of the earliest `KEYWORD: <timestamp>` at or after `init`, plus
-- the keyword. Mirrors Emacs `org-keyword-time-not-clock-regexp`: one
-- keyword, then one bracketed timestamp; a range's second half and any
-- prose after it are outside the match.
local function keyword_time(line, init, only)
  local best_s, best_e, best_kw
  for _, kw in ipairs(PLANNING_KEYWORDS) do
    if not only or only == kw then
      local s, e = line:find("%f[%w]" .. kw .. ":%s*[%[<][^%]>]+[%]>]", init)
      if s and (not best_s or s < best_s) then
        best_s, best_e, best_kw = s, e, kw
      end
    end
  end
  return best_s, best_e, best_kw
end

-- Drop `kw` from a planning line the way org-add-planning-info does:
-- from the keyword up to the next keyword-timestamp on the line, or to
-- the end of the line. Everything else -- a range's tail, a repeater, a
-- note -- rides along with whatever it follows.
local function drop_keyword(rest, kw)
  local s, e = keyword_time(rest, 1, kw)
  if not s then
    return rest
  end
  local nxt = keyword_time(rest, e + 1)
  return rest:sub(1, s - 1) .. rest:sub(nxt or (#rest + 1))
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
    level = #(line:match("^(%*+) ") or "*")
  end
  return M.section_indent_for(level, mode)
end

-- Set/update/clear one planning keyword under the headline at 0-based
-- `headline_row`, the way org-add-planning-info does: the keyword is
-- dropped from the headline's planning line and re-inserted at that
-- line's start; the rest of the line is carried over untouched, and a
-- line left with no keyword at all is removed.  With no planning line to
-- edit, one is inserted directly under the headline.  `kind` is
-- "SCHEDULED" | "DEADLINE" | "CLOSED"; `ts` is the timestamp string, or
-- nil to remove that keyword.
function M.set_planning(bufnr, headline_row, kind, ts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = element.planning_row(bufnr, headline_row)

  if not row then
    if ts then
      local line = M.planning_indent(bufnr, headline_row) .. kind .. ": " .. ts
      obuf.set_lines(bufnr, headline_row + 1, headline_row + 1, { line })
    end
    return
  end

  local indent, rest = (vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""):match(
    "^([ \t]*)(.*)$"
  )
  rest = drop_keyword(rest, kind):gsub("[ \t]+$", "")
  if not ts and rest == "" then
    obuf.set_lines(bufnr, row - 1, row, {})
    return
  end
  if ts then
    rest = kind .. ": " .. ts .. (rest == "" and "" or " " .. rest)
  end
  obuf.set_lines(bufnr, row - 1, row, { indent .. rest })
end

-- Reorder a headline's recognized prefix elements into canonical order:
-- planning -> property drawer -> LOGBOOK. CONSERVATIVE:
-- it only rewrites a contiguous region made up ENTIRELY of recognized element
-- lines; if any other line (blank, comment, body, unknown drawer) falls inside
-- that region it ABORTS without changes, so content is never lost or mangled.
-- The planning line is copied across verbatim: org reads it only directly
-- under the headline, so it is already first, and its text belongs to the
-- user.
-- No-op-safe writes: canonical input neither changes nor dirties the buffer.
function M.canonicalize(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local model = M.parse(bufnr, headline_row)

  local recognized = {}
  local planning_row = element.planning_row(bufnr, headline_row)
  if planning_row then
    recognized[planning_row] = true
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

  local block = {}
  if planning_row then
    block[1] = vim.api.nvim_buf_get_lines(bufnr, planning_row - 1, planning_row, false)[1] or ""
  end
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
