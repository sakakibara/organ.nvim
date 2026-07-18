-- The promote/demote command family is context-sensitive like Emacs's
-- meta-arrow commands: on a list item it indents/outdents the item
-- instead of warning "not on a headline".
--
--   promote / demote                 -> item + its children (Emacs
--                                       org-outdent/indent-item-tree)
--   promote_headline / demote_headline -> the item line only (Emacs
--                                       org-outdent/indent-item)
--
-- Run via: nvim --headless -l tests/list_meta_promote_demote_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local list = require("organ.list")

local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function run_cmd(path)
  local entry = require("organ").cmd(path)
  assert(entry and entry.fn, "subcommand `" .. path .. "` not registered")
  entry.fn({ args = "", fargs = {} })
end

local function eq(a, b)
  return vim.deep_equal(a, b)
end

local function detail(got)
  return "got:\n     " .. table.concat(got, "\n     ")
end

-- A `*` bullet needs leading whitespace (org spec); an unindented
-- `* foo` is a headline, never a list item.
do
  check("parse_item rejects unindented star", list.parse_item("* Heading") == nil)
  check(
    "parse_item accepts indented star bullet",
    (list.parse_item("  * item") or {}).bullet == "*"
  )
end

-- list.demote with tree=true carries children along.
do
  local b = buf_with({
    "- one",
    "- two",
    "  - child of two",
    "    deeper text",
    "- three",
  })
  list.demote(b, 2, { tree = true })
  local got = lines_of(b)
  check(
    "list.demote tree carries children",
    eq(got, {
      "- one",
      "  - two",
      "    - child of two",
      "      deeper text",
      "- three",
    }),
    detail(got)
  )
end

-- list.demote without tree moves only the item line (existing behavior).
do
  local b = buf_with({
    "- one",
    "- two",
    "  - child of two",
  })
  list.demote(b, 2)
  local got = lines_of(b)
  check(
    "list.demote item-only leaves children",
    eq(got, {
      "- one",
      "  - two",
      "  - child of two",
    }),
    detail(got)
  )
end

-- list.promote with tree=true carries children along.
do
  local b = buf_with({
    "- one",
    "  - two",
    "    - child of two",
    "      deeper text",
    "- three",
  })
  list.promote(b, 2, { tree = true })
  local got = lines_of(b)
  check(
    "list.promote tree carries children",
    eq(got, {
      "- one",
      "- two",
      "  - child of two",
      "    deeper text",
      "- three",
    }),
    detail(got)
  )
end

-- Numeric bullets: demote indents under the previous sibling's prefix
-- width (`1. ` -> 3 spaces); children follow, and the demoted item is
-- renumbered as the first item of its new sub-list.
do
  local b = buf_with({
    "1. one",
    "2. two",
    "   - child",
  })
  list.demote(b, 2, { tree = true })
  local got = lines_of(b)
  check(
    "list.demote tree numeric bullet",
    eq(got, {
      "1. one",
      "   1. two",
      "      - child",
    }),
    detail(got)
  )
end

-- `demote` command on a list item indents the item tree.
do
  local b = buf_with({
    "* H",
    "- one",
    "- two",
    "  - child of two",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  run_cmd("demote")
  local got = lines_of(b)
  check(
    "demote command on item indents item tree",
    eq(got, {
      "* H",
      "- one",
      "  - two",
      "    - child of two",
    }),
    detail(got)
  )
end

-- `promote` command on a list item outdents the item tree.
do
  local b = buf_with({
    "* H",
    "- one",
    "  - two",
    "    - child of two",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  run_cmd("promote")
  local got = lines_of(b)
  check(
    "promote command on item outdents item tree",
    eq(got, {
      "* H",
      "- one",
      "- two",
      "  - child of two",
    }),
    detail(got)
  )
end

-- `demote_headline` command on a list item indents the item line only.
do
  local b = buf_with({
    "- one",
    "- two",
    "  - child of two",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  run_cmd("demote_headline")
  local got = lines_of(b)
  check(
    "demote_headline command on item indents item only",
    eq(got, {
      "- one",
      "  - two",
      "  - child of two",
    }),
    detail(got)
  )
end

-- `promote_headline` command on a list item outdents the item line only.
do
  local b = buf_with({
    "- one",
    "  - two",
    "  - child of two",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  run_cmd("promote_headline")
  local got = lines_of(b)
  check(
    "promote_headline command on item outdents item only",
    eq(got, {
      "- one",
      "- two",
      "  - child of two",
    }),
    detail(got)
  )
end

-- Commands on a headline keep the headline behavior.
do
  local b = buf_with({
    "* H",
    "** child",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run_cmd("demote")
  local got = lines_of(b)
  check(
    "demote command on headline still demotes subtree",
    eq(got, {
      "** H",
      "*** child",
    }),
    detail(got)
  )
end

-- Demote on the whole list's first item indents the entire list one
-- column (Emacs org-shiftmetaright).
do
  local b = buf_with({
    "- one",
    "- two",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  run_cmd("demote")
  local got = lines_of(b)
  check(
    "demote command on the first item indents the whole list",
    eq(got, {
      " - one",
      " - two",
    }),
    detail(got)
  )
end

-- A separator line at the items' own indent bounds the structure scope:
-- an op inside the lower list must neither touch the earlier, deeper
-- list above the separator nor refuse because the scope leaked into it.
-- (Emacs's context finder folds even the separator prose into the
-- struct and reindents it; rewriting non-list prose is where we
-- deliberately stop following.)
do
  local b = buf_with({
    "  - deep one",
    "      - child",
    "",
    " note at indent 1",
    "",
    " - a",
    " - b",
  })
  local ok = list.demote(b, 7, { tree = true })
  local got = lines_of(b)
  check("demote below a separator ignores the earlier deeper list", ok == true and eq(got, {
    "  - deep one",
    "      - child",
    "",
    " note at indent 1",
    "",
    " - a",
    "   - b",
  }), detail(got))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("list_meta_promote_demote_test: PASS")
