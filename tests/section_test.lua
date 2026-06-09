-- Unit tests for lua/organ/section.lua: parse a headline's section into one
-- model, and answer where each element kind goes. Covers TS path + regex
-- fallback. Run: nvim --headless -l tests/section_test.lua
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

local section = require("organ.section")

-- Load lines into a real org buffer so the tree-sitter path is exercised.
local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(b, "filetype", "org")
  pcall(vim.treesitter.get_parser, b, "org")
  return b
end

-- 1. Full section: planning (combined line) + property drawer + LOGBOOK.
do
  local b = buf_with({
    "* DONE Full house",
    "  SCHEDULED: <2026-05-06 Wed> DEADLINE: <2026-05-07 Thu>",
    "  CLOSED: [2026-05-04 Mon 12:00]",
    "  :PROPERTIES:",
    "  :FOO: bar",
    "  :END:",
    "  :LOGBOOK:",
    "  CLOCK: [2026-05-04 Mon 12:00]--[2026-05-04 Mon 13:30] =>  1:30",
    "  :END:",
    "  body text",
  })
  local m = section.parse(b, 0)
  check("parse: headline_row echoed", m.headline_row == 0)
  check(
    "parse: scheduled line",
    m.planning.scheduled == 2,
    "got " .. tostring(m.planning.scheduled)
  )
  check("parse: deadline line", m.planning.deadline == 2, "got " .. tostring(m.planning.deadline))
  check("parse: closed line", m.planning.closed == 3, "got " .. tostring(m.planning.closed))
  check(
    "parse: planning_end past last planning line",
    m.planning_end == 4,
    "got " .. tostring(m.planning_end)
  )
  check(
    "parse: property drawer range",
    m.property_drawer ~= nil
      and m.property_drawer.start_line == 4
      and m.property_drawer.end_line == 6,
    vim.inspect(m.property_drawer)
  )
  check(
    "parse: logbook range",
    m.logbook ~= nil and m.logbook.start_line == 7 and m.logbook.end_line == 9,
    vim.inspect(m.logbook)
  )
end

-- 2. Bare headline: empty planning, no drawers.
do
  local b = buf_with({ "* TODO Bare", "  body" })
  local m = section.parse(b, 0)
  check(
    "parse bare: no planning",
    m.planning.scheduled == nil and m.planning.deadline == nil and m.planning.closed == nil
  )
  check(
    "parse bare: planning_end is headline+2",
    m.planning_end == 2,
    "got " .. tostring(m.planning_end)
  )
  check("parse bare: no property drawer", m.property_drawer == nil)
  check("parse bare: no logbook", m.logbook == nil)
end

-- 3. where(): drawer + property_drawer insertion rows.
do
  -- planning only, no drawers: both a new property drawer and a new
  -- named drawer go right after the planning block.
  local b = buf_with({
    "* TODO Plan only",
    "  SCHEDULED: <2026-05-06 Wed>",
    "  body",
  })
  check(
    "where property_drawer after planning",
    section.where(b, 0, "property_drawer") == 3,
    "got " .. tostring(section.where(b, 0, "property_drawer"))
  )
  check(
    "where drawer after planning",
    section.where(b, 0, "drawer") == 3,
    "got " .. tostring(section.where(b, 0, "drawer"))
  )
end
do
  -- with an existing property drawer, a new named drawer goes AFTER it.
  local b = buf_with({
    "* TODO Has props",
    "  :PROPERTIES:",
    "  :ID: x",
    "  :END:",
    "  body",
  })
  check(
    "where drawer after property drawer",
    section.where(b, 0, "drawer") == 5,
    "got " .. tostring(section.where(b, 0, "drawer"))
  )
  check(
    "where property_drawer with existing drawer points at its start",
    section.where(b, 0, "property_drawer") == 2,
    "got " .. tostring(section.where(b, 0, "property_drawer"))
  )
end

if fails > 0 then
  error(fails .. " checks failed")
end
print("\nAll checks passed.")
