-- Regression: element.planning_lines's REGEX FALLBACK (parser not loaded)
-- must find planning keywords placed AFTER a property drawer (org-habit
-- layout), matching the tree-sitter path. Run:
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

-- Stub out the parser so element.parser_loaded() returns false, forcing
-- the regex fallback path (mirrors the missing_parser_test approach).
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

if fails > 0 then
  error(fails .. " checks failed")
end
print("\nAll checks passed.")
