-- Emacs parity: list-item demote (indent under previous sibling).
--
-- Emacs's Tab on an empty list bullet runs `org-cycle` which dispatches
-- to `org-cycle-item-indentation` -- it demotes the item to become a
-- sub-item of the previous sibling.  Indent rule probed against
-- Emacs 30.2:
--   demoted indent = previous_sibling.indent + width(its_bullet_prefix)
-- e.g. `- one` (prefix `- ` width 2) -> `  - `; `1. one` (prefix `1. `
-- width 3) -> `   1. `.
--
-- Ordered lists: Emacs renumbers the lists an indent op touches (the
-- level the item left and the level it joined, each restarting at 1
-- unless a `[@N]` counter says otherwise), so the numbered cases below
-- probe renumbering as well as the indent column.
--
-- Run via: nvim --headless -l tests/parity_list_indent_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parity = dofile(root .. "/tests/_emacs_parity.lua")
parity.skip_if_no_emacs()

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

local function our_demote(input)
  local stripped, cursor = parity.parse_cursor(input)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(stripped, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, cursor)
  list.demote(b, cursor[1], { tree = true })
  local out_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return table.concat(out_lines, "\n") .. "\n"
end

local cases = {
  {
    label = "demote `- <CURSOR>` under `- one` -> 2-space indent",
    input = "- one\n- <CURSOR>\n- three\n",
  },
  {
    label = "demote `+ <CURSOR>` under `+ one` -> 2-space indent",
    input = "+ one\n+ <CURSOR>\n",
  },
  {
    label = "demote with already-indented prev sibling",
    input = "  - one\n  - <CURSOR>\n",
  },
  {
    label = "demote with content on the item (not just empty bullet)",
    input = "- one\n- <CURSOR>two\n- three\n",
  },
  {
    label = "demote ordered item renumbers both levels",
    input = "1. one\n2. <CURSOR>two\n3. three\n",
  },
  {
    label = "demote under a wide ordered bullet normalizes numbering",
    input = "10. ten\n11. <CURSOR>eleven\n",
  },
  {
    label = "demote across a single blank line (loose list stays one list)",
    input = "1. one\n\n2. <CURSOR>two\n3. three\n",
  },
  {
    label = "demote ordered item into unordered sub-list adopts its bullet",
    input = "1. one\n   - a\n2. <CURSOR>two\n",
  },
  {
    label = "demote unordered item into ordered sub-list adopts numbering",
    input = "1. one\n   1. a\n- <CURSOR>two\n",
  },
  {
    label = "demote `+` item into `-` sub-list adopts the dash",
    input = "- one\n  - a\n+ <CURSOR>two\n",
  },
  {
    label = "demote `.` item into `)` sub-list adopts the separator",
    input = "1. one\n   1) a\n2. <CURSOR>two\n",
  },
}

for _, c in ipairs(cases) do
  local emacs_out = parity.run("list-demote", c.input)
  local our_out = our_demote(c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

local function our_promote(input)
  local stripped, cursor = parity.parse_cursor(input)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(stripped, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, cursor)
  list.promote(b, cursor[1], { tree = true })
  local out_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return table.concat(out_lines, "\n") .. "\n"
end

local promote_cases = {
  {
    label = "promote `  - <CURSOR>` -> `- ` (un-indent under root)",
    input = "- one\n  - <CURSOR>\n- three\n",
  },
  {
    label = "promote nested 4-space indent to 2-space (one level up)",
    input = "- one\n  - two\n    - <CURSOR>three\n",
  },
  {
    label = "promote ordered sub-item renumbers both levels",
    input = "1. one\n   1. sub one\n   2. <CURSOR>sub two\n2. two\n",
  },
  {
    label = "promote out of the middle splits the sub-list, both halves renumber",
    input = "1. one\n   1. a\n   2. <CURSOR>b\n   3. c\n2. two\n",
  },
  {
    label = "promote item with continuation text renumbers the sibling after it",
    input = "1. one\n   1. a\n   2. <CURSOR>b\n      cont text\n2. two\n",
  },
  {
    label = "promote unordered item into ordered outer list adopts numbering",
    input = "1. one\n   - <CURSOR>sub\n2. two\n",
  },
}

for _, c in ipairs(promote_cases) do
  local emacs_out = parity.run("list-promote", c.input)
  local our_out = our_promote(c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_list_indent_test: PASS")
