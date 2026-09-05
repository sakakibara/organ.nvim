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

-- 1. Full section: planning (one line) + property drawer + LOGBOOK.
do
  local b = buf_with({
    "* DONE Full house",
    "  SCHEDULED: <2026-05-06 Wed> DEADLINE: <2026-05-07 Thu> CLOSED: [2026-05-04 Mon 12:00]",
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
  check("parse: closed line", m.planning.closed == 2, "got " .. tostring(m.planning.closed))
  check(
    "parse: planning_end past the planning line",
    m.planning_end == 3,
    "got " .. tostring(m.planning_end)
  )
  check(
    "parse: property drawer range",
    m.property_drawer ~= nil
      and m.property_drawer.start_line == 3
      and m.property_drawer.end_line == 5,
    vim.inspect(m.property_drawer)
  )
  check(
    "parse: logbook range",
    m.logbook ~= nil and m.logbook.start_line == 6 and m.logbook.end_line == 8,
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

-- 5. set_planning follows org-add-planning-info: the keyword being set is
-- removed from the single planning line and re-inserted at its start; the
-- other keywords keep their order.
do
  local b = buf_with({
    "* TODO Combined",
    "  SCHEDULED: <2026-05-06 Wed> DEADLINE: <2026-05-07 Thu>",
    "  body",
  })
  section.set_planning(b, 0, "DEADLINE", "<2026-05-08 Fri>")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning: updated keyword moves to the front of the one planning line",
    vim.deep_equal(got, {
      "* TODO Combined",
      "  DEADLINE: <2026-05-08 Fri> SCHEDULED: <2026-05-06 Wed>",
      "  body",
    }),
    vim.inspect(got)
  )
end
do
  local b = buf_with({ "* T", "body" })
  section.set_planning(b, 0, "SCHEDULED", "<2025-01-02 Thu>")
  section.set_planning(b, 0, "DEADLINE", "<2025-01-01 Wed>")
  section.set_planning(b, 0, "SCHEDULED", "<2025-01-09 Thu>")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning: schedule, deadline, reschedule -> Emacs layout",
    vim.deep_equal(got, {
      "* T",
      "  SCHEDULED: <2025-01-09 Thu> DEADLINE: <2025-01-01 Wed>",
      "body",
    }),
    vim.inspect(got)
  )
  check(
    "set_planning: grammar sees one planning node ending before the body",
    require("organ.element").planning_end_line(b, 0) == 3,
    "got " .. tostring(require("organ.element").planning_end_line(b, 0))
  )
  section.set_planning(b, 0, "SCHEDULED", nil)
  got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning: removing one keyword keeps the rest",
    vim.deep_equal(got, { "* T", "  DEADLINE: <2025-01-01 Wed>", "body" }),
    vim.inspect(got)
  )
  section.set_planning(b, 0, "DEADLINE", nil)
  got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning: removing the last keyword deletes the planning line",
    vim.deep_equal(got, { "* T", "body" }),
    vim.inspect(got)
  )
end
-- A second keyword line is a paragraph, not planning (org reads planning
-- from the one line under the headline), so the write leaves it alone.
do
  local b = buf_with({
    "* TODO Legacy",
    "  SCHEDULED: <2026-05-06 Wed>",
    "  DEADLINE: <2026-05-07 Thu>",
    "  body",
  })
  section.set_planning(b, 0, "CLOSED", "[2026-05-04 Mon 12:00]")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning: a keyword line below the planning line is left as body",
    vim.deep_equal(got, {
      "* TODO Legacy",
      "  CLOSED: [2026-05-04 Mon 12:00] SCHEDULED: <2026-05-06 Wed>",
      "  DEADLINE: <2026-05-07 Thu>",
      "  body",
    }),
    vim.inspect(got)
  )
end
do
  local b = buf_with({
    "* TODO Habit",
    "  SCHEDULED: <2026-05-06 Wed>",
    "  :PROPERTIES:",
    "  :STYLE: habit",
    "  :END:",
    "  CLOSED: [2026-05-04 Mon 12:00]",
    "  body",
  })
  section.set_planning(b, 0, "DEADLINE", "<2026-05-07 Thu>")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning: a keyword line below a drawer is body and stays put",
    vim.deep_equal(got, {
      "* TODO Habit",
      "  DEADLINE: <2026-05-07 Thu> SCHEDULED: <2026-05-06 Wed>",
      "  :PROPERTIES:",
      "  :STYLE: habit",
      "  :END:",
      "  CLOSED: [2026-05-04 Mon 12:00]",
      "  body",
    }),
    vim.inspect(got)
  )
end
do
  local b = buf_with({ "* TODO Fresh", "  body" })
  section.set_planning(b, 0, "SCHEDULED", "<2026-05-06 Wed>")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning: fresh scheduled after headline",
    vim.deep_equal(got, {
      "* TODO Fresh",
      "  SCHEDULED: <2026-05-06 Wed>",
      "  body",
    }),
    vim.inspect(got)
  )
end
do
  local b = buf_with({ "* DONE Keep", "  CLOSED: [2026-05-04 Mon 12:00]", "  body" })
  section.set_planning(b, 0, "SCHEDULED", "<2026-05-06 Wed>")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "set_planning: preserves CLOSED after the new keyword",
    vim.deep_equal(got, {
      "* DONE Keep",
      "  SCHEDULED: <2026-05-06 Wed> CLOSED: [2026-05-04 Mon 12:00]",
      "  body",
    }),
    vim.inspect(got)
  )
end

-- 6. planning_indent honors config + adapts to headline level.
do
  local b = buf_with({ "** TODO Deep", "  body" })
  check(
    "planning_indent adapt: level 2 -> 3 spaces",
    section.planning_indent(b, 0) == "   ",
    "got " .. string.format("%q", section.planning_indent(b, 0))
  )
end

-- 7. canonicalize: no-op on already-canonical organ output.
do
  local b = buf_with({
    "* DONE Task",
    "  CLOSED: [2026-05-04 Mon 12:00] SCHEDULED: <2026-05-06 Wed> DEADLINE: <2026-05-07 Thu>",
    "  :PROPERTIES:",
    "  :FOO: bar",
    "  :END:",
    "  :LOGBOOK:",
    "  CLOCK: [2026-05-04 Mon 12:00]--[2026-05-04 Mon 13:30] =>  1:30",
    "  :END:",
    "  body",
  })
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.bo[b].modified = false
  section.canonicalize(b, 0)
  local after = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("canonicalize: no-op on canonical input", vim.deep_equal(before, after), vim.inspect(after))
  check("canonicalize: canonical input stays unmodified", vim.bo[b].modified == false)
end

-- 8. canonicalize: a SCHEDULED line below the property drawer is a
-- paragraph to org, so hoisting it would invent planning data.
do
  local b = buf_with({
    "* TODO Task",
    "  :PROPERTIES:",
    "  :FOO: bar",
    "  :END:",
    "  SCHEDULED: <2026-05-06 Wed>",
    "  body",
  })
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  section.canonicalize(b, 0)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "canonicalize: a keyword line below the drawer stays body",
    vim.deep_equal(got, before),
    vim.inspect(got)
  )
end

-- 9. canonicalize: only the line under the headline is planning; the one
-- below it is a paragraph and neither line is rewritten.
do
  local b = buf_with({
    "* TODO Task",
    "  DEADLINE: <2026-05-07 Thu>",
    "  SCHEDULED:   <2026-05-06 Wed>",
    "  body",
  })
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  section.canonicalize(b, 0)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "canonicalize: a second keyword line is left alone",
    vim.deep_equal(got, before),
    vim.inspect(got)
  )
end

-- 10. canonicalize: SAFETY -- a blank line within the prefix region aborts.
do
  local b = buf_with({
    "* TODO Task",
    "  :PROPERTIES:",
    "  :FOO: bar",
    "  :END:",
    "",
    "  SCHEDULED: <2026-05-06 Wed>",
    "  body",
  })
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  section.canonicalize(b, 0)
  local after = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "canonicalize: aborts when a blank splits the prefix region",
    vim.deep_equal(before, after),
    vim.inspect(after)
  )
end

-- 11. canonicalize: SAFETY -- an unknown drawer within the region aborts.
do
  local b = buf_with({
    "* TODO Task",
    "  SCHEDULED: <2026-05-06 Wed>",
    "  :CUSTOM:",
    "  stuff",
    "  :END:",
    "  :LOGBOOK:",
    "  CLOCK: [2026-05-04 Mon 12:00]--[2026-05-04 Mon 13:30] =>  1:30",
    "  :END:",
    "  body",
  })
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  section.canonicalize(b, 0)
  local after = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "canonicalize: aborts on an unknown drawer in the region",
    vim.deep_equal(before, after),
    vim.inspect(after)
  )
end

-- 12. canonicalize: empty section is a no-op.
do
  local b = buf_with({ "* TODO Bare", "  body" })
  local before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  section.canonicalize(b, 0)
  check(
    "canonicalize: no recognized prefix -> no-op",
    vim.deep_equal(before, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  )
end

if fails > 0 then
  error(fails .. " checks failed")
end
print("\nAll checks passed.")
