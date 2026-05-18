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
-- Numeric-list renumbering after indent change is NOT covered here:
-- Emacs renumbers the whole list when demotion changes which items
-- are siblings; our implementation indents only.  TODO when we wire
-- numeric renumbering into demote / promote.  Test cases use literal
-- (`-` / `+`) bullets only for now.
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
  list.demote(b, cursor[1])
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
  list.promote(b, cursor[1])
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
