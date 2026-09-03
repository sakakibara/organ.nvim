-- Regression: element.planning_lines is a tolerant line scan (per Emacs
-- org-add-planning-info) -- the sole implementation, by design, not a
-- fallback for a stricter tree-sitter path (strict TS readers live
-- elsewhere). It must find planning keywords placed AFTER a property
-- drawer (org-habit layout), and must NOT mistake body prose or an
-- unrelated keyword (RESCHEDULED) for planning. Run:
--   nvim --headless -l tests/element_planning_lines_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local element = require("organ.element")

-- Stub out the parser (mirrors the missing_parser_test approach) so these
-- checks run with no tree-sitter involvement at all.
local orig_get_parser = vim.treesitter.get_parser
local function no_parser()
  error("simulated: parser not available")
end

local function noparser_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- org-habit layout: property drawer BEFORE the SCHEDULED line.
do
  local b = noparser_buf({
    "* TODO Water plants",
    "  :PROPERTIES:",
    "  :STYLE: habit",
    "  :END:",
    "  SCHEDULED: <2026-05-06 Wed ++3d>",
  })
  vim.treesitter.get_parser = no_parser
  element.invalidate(b)
  check(
    "regex fallback is the path under test (parser not loaded)",
    element.parser_loaded(b) == false
  )
  local pl = element.planning_lines(b, 0)
  vim.treesitter.get_parser = orig_get_parser
  element.invalidate(b)
  check(
    "scheduled found after the property drawer",
    pl.scheduled == 5,
    "got " .. tostring(pl.scheduled)
  )
end

-- Plain layout still works: planning directly after the headline.
do
  local b = noparser_buf({
    "* TODO Plain",
    "  SCHEDULED: <2026-05-06 Wed>",
    "  DEADLINE: <2026-05-07 Thu>",
  })
  vim.treesitter.get_parser = no_parser
  element.invalidate(b)
  local pl = element.planning_lines(b, 0)
  vim.treesitter.get_parser = orig_get_parser
  element.invalidate(b)
  check("plain scheduled", pl.scheduled == 2, "got " .. tostring(pl.scheduled))
  check("plain deadline", pl.deadline == 3, "got " .. tostring(pl.deadline))
end

-- No planning at all -> empty.
do
  local b = noparser_buf({ "* TODO Nothing", "  body" })
  vim.treesitter.get_parser = no_parser
  element.invalidate(b)
  local pl = element.planning_lines(b, 0)
  vim.treesitter.get_parser = orig_get_parser
  element.invalidate(b)
  check("no planning -> nil", pl.scheduled == nil and pl.deadline == nil and pl.closed == nil)
end

-- Unterminated drawer running into the next headline must NOT leak the
-- sibling headline's planning into this headline's result.
do
  local b = noparser_buf({
    "* TODO Broken",
    "  :LOGBOOK:",
    "  CLOCK: [2026-05-04 Mon 12:00]",
    "* TODO Sibling",
    "  SCHEDULED: <2026-05-06 Wed>",
  })
  local pl = element.planning_lines(b, 0)
  check(
    "unterminated drawer does not leak sibling planning",
    pl.scheduled == nil,
    "got " .. tostring(pl.scheduled)
  )
end

-- Body prose that merely contains a planning keyword as a substring must
-- NOT register as planning -- section.set_planning does a whole-line
-- replacement keyed on these entries, so a false hit here would destroy
-- the prose line.
do
  local b = noparser_buf({
    "* TODO Water plants",
    "  Meeting DEADLINE: is strict, see notes",
  })
  vim.treesitter.get_parser = no_parser
  element.invalidate(b)
  local pl = element.planning_lines(b, 0)
  vim.treesitter.get_parser = orig_get_parser
  element.invalidate(b)
  check(
    "prose containing 'DEADLINE:' is not registered as planning",
    pl.deadline == nil,
    "got " .. tostring(pl.deadline)
  )
end

-- A body line that contains keyword + timestamp mid-line is prose too:
-- Emacs org-planning-line-re anchors the first keyword at line start.
do
  local b = noparser_buf({
    "* Task",
    "Was SCHEDULED: <2024-01-01 Mon> originally, see CLOSED: [2024-02-02 Fri] note",
    "more body",
  })
  vim.treesitter.get_parser = no_parser
  element.invalidate(b)
  local pl = element.planning_lines(b, 0)
  vim.treesitter.get_parser = orig_get_parser
  element.invalidate(b)
  check(
    "prose with mid-line 'SCHEDULED: <ts>' is not planning",
    pl.scheduled == nil and pl.closed == nil,
    vim.inspect(pl)
  )
  require("organ.section").set_planning(b, 0, "DEADLINE", "<2025-01-01 Wed>")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning inserts a new line and leaves the prose intact",
    vim.deep_equal(got, {
      "* Task",
      "  DEADLINE: <2025-01-01 Wed>",
      "Was SCHEDULED: <2024-01-01 Mon> originally, see CLOSED: [2024-02-02 Fri] note",
      "more body",
    }),
    vim.inspect(got)
  )
end

-- A planning line still reports every keyword it carries.
do
  local b = noparser_buf({
    "* Task",
    "  CLOSED: [2024-02-02 Fri] DEADLINE: <2024-01-05 Fri> SCHEDULED: <2024-01-01 Mon>",
  })
  vim.treesitter.get_parser = no_parser
  element.invalidate(b)
  local pl = element.planning_lines(b, 0)
  vim.treesitter.get_parser = orig_get_parser
  element.invalidate(b)
  check(
    "combined planning line reports all three keywords",
    pl.scheduled == 2 and pl.deadline == 2 and pl.closed == 2,
    vim.inspect(pl)
  )
end

-- RESCHEDULED: is a distinct keyword, not SCHEDULED: with a prefix --
-- the word-frontier anchor must reject it.
do
  local b = noparser_buf({
    "* TODO Water plants",
    "  RESCHEDULED: <2026-08-01 Sat>",
  })
  vim.treesitter.get_parser = no_parser
  element.invalidate(b)
  local pl = element.planning_lines(b, 0)
  vim.treesitter.get_parser = orig_get_parser
  element.invalidate(b)
  check(
    "RESCHEDULED: is not registered as scheduled",
    pl.scheduled == nil,
    "got " .. tostring(pl.scheduled)
  )
end

if fails > 0 then
  error(fails .. " checks failed")
end
print("\nAll checks passed.")
