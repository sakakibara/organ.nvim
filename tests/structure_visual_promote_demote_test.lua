-- Visual-mode promote/demote keymaps: select multiple trees, press the
-- chord, every selected heading shifts one level.  Bare `<`/`>` stays
-- context-aware (native indent when no heading is selected).
-- Run via: nvim --headless -l tests/structure_visual_promote_demote_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")
require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Build a real org buffer in a window with the ftplugin attached.
local function fresh(lines)
  local tmp = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, tmp)
  vim.cmd("edit " .. tmp)
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].filetype = "org"
  vim.cmd("doautocmd FileType")
  return b
end
local function lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

-- `>` over a multi-tree selection demotes every selected heading.
do
  local b = fresh({ "* One", "body", "* Two", "** Two-child", "* Three" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed("V4j>") -- linewise visual over all 5 lines, then >
  local l = lines(b)
  check("visual > : One demoted", l[1] == "** One", l[1])
  check("visual > : body untouched", l[2] == "body", l[2])
  check("visual > : Two demoted", l[3] == "** Two", l[3])
  check("visual > : Two-child demoted (relative preserved)", l[4] == "*** Two-child", l[4])
  check("visual > : Three demoted", l[5] == "** Three", l[5])
end

-- `<` over a multi-tree selection promotes every selected heading.
do
  local b = fresh({ "** One", "** Two", "*** Two-child" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed("V2j<")
  local l = lines(b)
  check("visual < : One promoted", l[1] == "* One", l[1])
  check("visual < : Two promoted", l[2] == "* Two", l[2])
  check("visual < : Two-child promoted", l[3] == "** Two-child", l[3])
end

-- count: `2>` demotes twice.
do
  local b = fresh({ "* One", "* Two" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed("Vj2>")
  local l = lines(b)
  check("visual 2> : One demoted twice", l[1] == "*** One", l[1])
  check("visual 2> : Two demoted twice", l[2] == "*** Two", l[2])
end

-- Context-aware `>`: selection with NO heading falls through to native
-- visual indent (body lines gain leading whitespace; no star change).
do
  local b = fresh({ "* Heading", "alpha", "beta" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  feed("Vj>") -- select lines 2-3 (alpha, beta) only, indent
  local l = lines(b)
  check("native indent: heading untouched", l[1] == "* Heading", l[1])
  check(
    "native indent: alpha gained leading whitespace",
    l[2]:match("^%s+alpha$") ~= nil,
    "[" .. l[2] .. "]"
  )
  check(
    "native indent: beta gained leading whitespace",
    l[3]:match("^%s+beta$") ~= nil,
    "[" .. l[3] .. "]"
  )
  check("native indent: alpha still not a heading", l[2]:match("^%*") == nil)
end

-- Alt chord `<M-l>` over a heading selection demotes.
do
  local b = fresh({ "* One", "* Two" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed("Vj<M-l>")
  local l = lines(b)
  check("visual <M-l> : One demoted", l[1] == "** One", l[1])
  check("visual <M-l> : Two demoted", l[2] == "** Two", l[2])
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("structure_visual_promote_demote_test: PASS")
