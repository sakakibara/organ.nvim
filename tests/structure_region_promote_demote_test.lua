-- Region promote/demote: shift the level of EVERY heading in a line
-- range by one step (Emacs region M-LEFT/M-RIGHT behaviour).  Used by
-- the visual-mode promote/demote bindings.
-- Run via: nvim --headless -l tests/structure_region_promote_demote_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
local structure = require("organ.structure")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  return b
end
local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- _range_has_headline
do
  local b = mkbuf({ "* A", "body", "** B", "plain text" })
  check("range_has_headline: heading in range", structure._range_has_headline(b, 1, 2) == true)
  check("range_has_headline: only body", structure._range_has_headline(b, 2, 2) == false)
  check("range_has_headline: spans heading", structure._range_has_headline(b, 2, 3) == true)
  check("range_has_headline: plain only", structure._range_has_headline(b, 4, 4) == false)
end

-- demote_region: every heading in range gains a star; non-heading lines untouched
do
  local b = mkbuf({ "* One", "body one", "* Two", "** Two-child", "* Three" })
  local err = structure.demote_region({ bufnr = b, start_line = 1, end_line = 5 })
  check("demote_region: no error", err == nil, tostring(err))
  local l = lines(b)
  check("demote: One -> **", l[1] == "** One", l[1])
  check("demote: body untouched", l[2] == "body one", l[2])
  check("demote: Two -> **", l[3] == "** Two", l[3])
  check("demote: Two-child -> *** (relative structure preserved)", l[4] == "*** Two-child", l[4])
  check("demote: Three -> **", l[5] == "** Three", l[5])
end

-- promote_region: every heading loses a star
do
  local b = mkbuf({ "** One", "body", "** Two", "*** Two-child" })
  local err = structure.promote_region({ bufnr = b, start_line = 1, end_line = 4 })
  check("promote_region: no error", err == nil, tostring(err))
  local l = lines(b)
  check("promote: One -> *", l[1] == "* One", l[1])
  check("promote: Two -> *", l[3] == "* Two", l[3])
  check("promote: Two-child -> ** (relative preserved)", l[4] == "** Two-child", l[4])
end

-- promote_region: atomic bounds error when any heading is level-1 (no change)
do
  local b = mkbuf({ "* One", "** Two" })
  local err = structure.promote_region({ bufnr = b, start_line = 1, end_line = 2 })
  check("promote at level-1: returns error", err ~= nil and err:find("level%-1") ~= nil, tostring(err))
  local l = lines(b)
  check("promote at level-1: nothing changed (atomic)", l[1] == "* One" and l[2] == "** Two", table.concat(l, "|"))
end

-- demote_region: atomic bounds error at level 9
do
  local b = mkbuf({ "********* Deep", "body" }) -- 9 stars
  local err = structure.demote_region({ bufnr = b, start_line = 1, end_line = 2 })
  check("demote at level-9: returns error", err ~= nil and err:find("level 9") ~= nil, tostring(err))
  check("demote at level-9: unchanged", lines(b)[1] == "********* Deep")
end

-- partial selection: only headings inside the range shift
do
  local b = mkbuf({ "* One", "** One-child", "* Two" })
  -- select only lines 2-3 (One-child + Two), not One
  structure.demote_region({ bufnr = b, start_line = 2, end_line = 3 })
  local l = lines(b)
  check("partial: One untouched (outside range)", l[1] == "* One", l[1])
  check("partial: One-child demoted", l[2] == "*** One-child", l[2])
  check("partial: Two demoted", l[3] == "** Two", l[3])
end

-- no heading in range: no-op, no error
do
  local b = mkbuf({ "* One", "body a", "body b" })
  local err = structure.demote_region({ bufnr = b, start_line = 2, end_line = 3 })
  check("no-heading range: no error", err == nil)
  check("no-heading range: unchanged", lines(b)[1] == "* One" and lines(b)[2] == "body a")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("structure_region_promote_demote_test: PASS")
