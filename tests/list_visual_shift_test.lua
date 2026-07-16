-- Visual-mode promote/demote on list items: selecting item lines and
-- pressing the promote/demote chords shifts every selected line as a
-- block, one indent level per count (Emacs region `org-indent-item` /
-- `org-outdent-item`: "if a region is active, all items inside will be
-- moved").  Dispatch follows Emacs: a selection containing a headline
-- keeps the headline behavior; otherwise the selection must START on a
-- list item.  Bare `<` / `>` keep Vim's native visual indent.
--
-- Run via: nvim --headless -l tests/list_visual_shift_test.lua

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

local list = require("organ.list")

local function fresh(lines)
  local tmp = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, tmp)
  vim.cmd("edit " .. tmp)
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].filetype = "org"
  vim.cmd("doautocmd FileType")
  return b
end
local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local function eq(a, b)
  return vim.deep_equal(a, b)
end
local function detail(got)
  return "got:\n     " .. table.concat(got, "\n     ")
end

-- shift_region unit: block-demote sibling items under the previous
-- sibling; relative structure preserved.
do
  local b = fresh({ "- a", "- b", "  - b child", "- c", "- d" })
  local moved = list.shift_region(b, 2, 4, "demote")
  local got = lines_of(b)
  check(
    "shift_region demote moves block under previous sibling",
    moved == true and eq(got, { "- a", "  - b", "    - b child", "  - c", "- d" }),
    detail(got)
  )
end

do
  local b = fresh({ "- a", "  - b", "    - b child", "  - c" })
  local moved = list.shift_region(b, 2, 4, "promote")
  local got = lines_of(b)
  check(
    "shift_region promote moves block to ancestor indent",
    moved == true and eq(got, { "- a", "- b", "  - b child", "- c" }),
    detail(got)
  )
end

-- Region must start on an item (Emacs: "Region not starting at an item").
do
  local b = fresh({ "text", "- a", "- b" })
  local moved = list.shift_region(b, 1, 3, "demote")
  local got = lines_of(b)
  check(
    "shift_region rejects region not starting on an item",
    moved == false and eq(got, { "text", "- a", "- b" }),
    detail(got)
  )
end

-- First selected item with no previous sibling: no-op.
do
  local b = fresh({ "- a", "- b" })
  local moved = list.shift_region(b, 1, 2, "demote")
  local got = lines_of(b)
  check(
    "shift_region demote without previous sibling is a no-op",
    moved == false and eq(got, { "- a", "- b" }),
    detail(got)
  )
end

-- <M-l> over selected sibling items indents the block.
do
  local b = fresh({ "* H", "- a", "- b", "  - b child", "- c" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  feed("V2j<M-l>")
  local got = lines_of(b)
  check(
    "visual <M-l> indents selected items as a block",
    eq(got, { "* H", "- a", "  - b", "    - b child", "  - c" }),
    detail(got)
  )
end

-- <M-h> reverses it.
do
  local b = fresh({ "* H", "- a", "  - b", "    - b child", "  - c" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  feed("V2j<M-h>")
  local got = lines_of(b)
  check(
    "visual <M-h> outdents selected items as a block",
    eq(got, { "* H", "- a", "- b", "  - b child", "- c" }),
    detail(got)
  )
end

-- count: 2<M-l> indents twice.
do
  local b = fresh({ "- a", "  - b", "- c" })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  feed("V2<M-l>")
  local got = lines_of(b)
  check("visual 2<M-l> indents twice", eq(got, { "- a", "  - b", "    - c" }), detail(got))
end

-- Selection containing a headline keeps the headline behavior even
-- when it also contains items.
do
  local b = fresh({ "* H", "- a", "- b" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed("V2j<M-l>")
  local got = lines_of(b)
  check(
    "visual <M-l> with headline in selection shifts the headline",
    eq(got, { "** H", "- a", "- b" }),
    detail(got)
  )
end

-- Bare `>` on an item selection keeps Vim's native indent.
do
  local b = fresh({ "- a", "- b", "- c" })
  vim.bo.shiftwidth = 4
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  feed("Vj>")
  local got = lines_of(b)
  check(
    "visual > on items stays native shiftwidth indent",
    eq(got, { "- a", "    - b", "    - c" }),
    detail(got)
  )
end

-- Alt chord on a selection with neither headline nor leading item does
-- nothing.
do
  local b = fresh({ "* H", "plain body", "more body" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  feed("Vj<M-l>")
  local got = lines_of(b)
  check(
    "visual <M-l> on plain body is a no-op",
    eq(got, { "* H", "plain body", "more body" }),
    detail(got)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("list_visual_shift_test: PASS")
