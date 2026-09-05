-- canonicalize / format keep every existing planning + drawer line at the
-- indent it already has (Emacs `org-adapt-indentation` is nil, and
-- `todo.planning_indent` governs only newly-inserted lines).  Run via:
-- nvim --headless -l tests/section_drawer_indent_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  return b
end

do
  local b = mkbuf({
    "* TODO Task",
    "DEADLINE: <2026-06-17 Wed>",
    ":PROPERTIES:",
    ":ID: abc",
    ":END:",
    ":LOGBOOK:",
    "CLOCK: [2026-06-16 Tue 09:00]",
    ":END:",
    "body text",
  })
  require("organ.format").format_buffer(b)
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(out[2] == "DEADLINE: <2026-06-17 Wed>", "flush planning stays flush")
  check(out[3] == ":PROPERTIES:", "flush property drawer open stays flush")
  check(out[4] == ":ID:       abc", "property line org-property-format aligned")
  check(out[5] == ":END:", "flush property drawer close stays flush")
  check(out[6] == ":LOGBOOK:", "flush logbook drawer open stays flush")
  check(out[7] == "CLOCK: [2026-06-16 Tue 09:00]", "flush logbook line stays flush")
  check(out[9] == "body text", "body stays flush")
end

do
  local b = mkbuf({
    "* TODO Task",
    "  DEADLINE: <2026-06-17 Wed>",
    "  :PROPERTIES:",
    "  :ID:       abc",
    "  :END:",
    "  :LOGBOOK:",
    "  CLOCK: [2026-06-16 Tue 09:00]",
    "  :END:",
  })
  require("organ.format").format_buffer(b)
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(out[2] == "  DEADLINE: <2026-06-17 Wed>", "indented planning keeps its indent")
  check(out[3] == "  :PROPERTIES:", "indented property drawer open keeps its indent")
  check(out[4] == "  :ID:       abc", "indented property line keeps its indent")
  check(out[6] == "  :LOGBOOK:", "indented logbook drawer open keeps its indent")
  check(out[7] == "  CLOCK: [2026-06-16 Tue 09:00]", "indented logbook line keeps its indent")
end

-- A LOGBOOK note's continuation lines carry an indent deeper than the
-- drawer's; flattening them detaches the body from its note item.
do
  local b = mkbuf({
    "* TODO Thing",
    ":LOGBOOK:",
    "- Note taken on [2026-01-01 Thu 10:00] \\\\",
    "  first line of note",
    "  second line of note",
    ":END:",
  })
  require("organ.format").format_buffer(b)
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(out[3] == "- Note taken on [2026-01-01 Thu 10:00] \\\\", "note item preserved")
  check(out[4] == "  first line of note", "note continuation keeps its indent")
  check(out[5] == "  second line of note", "second note continuation keeps its indent")
end

-- A DEADLINE line below the drawer is body text to org, so it keeps both
-- its place and its indent.
do
  local b = mkbuf({
    "* TODO Task",
    "  :PROPERTIES:",
    "  :ID:       abc",
    "  :END:",
    "DEADLINE: <2026-06-17 Wed>",
  })
  require("organ.format").format_buffer(b)
  local out = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(out[2] == "  :PROPERTIES:", "property drawer stays first, indent kept")
  check(out[4] == "  :END:", "property drawer close kept")
  check(out[5] == "DEADLINE: <2026-06-17 Wed>", "the keyword line below it stays body")
end

print("ALL PASS: section_drawer_indent")
