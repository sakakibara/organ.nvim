-- Emacs parity: list-item promote / demote.
--
-- Probed against Emacs 30.2. `org-shiftmeta<arrow>` moves the item with
-- its subtree; `org-meta<arrow>` moves only the item and its own body.
-- Emacs models a list as a struct: an item's parent is the closest item
-- above with smaller indent, siblings share a parent (indent equality is
-- NOT required), and every op ends by normalizing the whole structure --
-- indentation from each parent's bullet width, one bullet style per
-- list (the first item's), numbering restarting at 1 unless an `[@N]`
-- counter overrides.  On the WHOLE list's first item, demote / promote
-- shift the entire list one column instead.  Two ops refuse: demoting
-- the first item of a sub-list, and outdenting an item without its
-- children (item-only promote of an item that has child items).
--
-- A `refuse = true` case asserts BOTH sides reject: Emacs signals a
-- user error and organ returns false leaving the buffer untouched.
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

-- Run organ's op for `case`; returns output text + the op's return value.
local function ours(case)
  local stripped, cursor = parity.parse_cursor(case.input)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(stripped, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, cursor)
  local fn = case.op:find("demote") and list.demote or list.promote
  local changed = fn(b, cursor[1], { tree = case.op:find("item") == nil })
  local out_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return table.concat(out_lines, "\n") .. "\n", changed
end

local function run_case(c)
  local our_out, changed = ours(c)
  if c.refuse then
    local ok = pcall(parity.run, c.op, c.input)
    local input_text = (parity.parse_cursor(c.input))
    check(
      c.label,
      not ok and changed == false and our_out == input_text,
      string.format(
        "emacs_refused=%s ours_changed=%s ours=%q",
        tostring(not ok),
        tostring(changed),
        our_out
      )
    )
    return
  end
  local emacs_out = parity.run(c.op, c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

local cases = {
  -- subtree demote (org-shiftmetaright)
  {
    label = "demote `- <CURSOR>` under `- one` -> 2-space indent",
    op = "list-demote",
    input = "- one\n- <CURSOR>\n- three\n",
  },
  {
    label = "demote `+ <CURSOR>` under `+ one` -> 2-space indent",
    op = "list-demote",
    input = "+ one\n+ <CURSOR>\n",
  },
  {
    label = "demote with already-indented prev sibling",
    op = "list-demote",
    input = "  - one\n  - <CURSOR>\n",
  },
  {
    label = "demote with content on the item (not just empty bullet)",
    op = "list-demote",
    input = "- one\n- <CURSOR>two\n- three\n",
  },
  {
    label = "demote ordered item renumbers both levels",
    op = "list-demote",
    input = "1. one\n2. <CURSOR>two\n3. three\n",
  },
  {
    label = "demote under a wide ordered bullet normalizes numbering",
    op = "list-demote",
    input = "10. ten\n11. <CURSOR>eleven\n",
  },
  {
    label = "demote across a single blank line (loose list stays one list)",
    op = "list-demote",
    input = "1. one\n\n2. <CURSOR>two\n3. three\n",
  },
  {
    label = "demote ordered item into unordered sub-list adopts its bullet",
    op = "list-demote",
    input = "1. one\n   - a\n2. <CURSOR>two\n",
  },
  {
    label = "demote unordered item into ordered sub-list adopts numbering",
    op = "list-demote",
    input = "1. one\n   1. a\n- <CURSOR>two\n",
  },
  {
    label = "demote `+` item into `-` sub-list adopts the dash",
    op = "list-demote",
    input = "- one\n  - a\n+ <CURSOR>two\n",
  },
  {
    label = "demote `.` item into `)` sub-list adopts the separator",
    op = "list-demote",
    input = "1. one\n   1) a\n2. <CURSOR>two\n",
  },
  {
    label = "demote honors a mid-list [@N] counter",
    op = "list-demote",
    input = "1. one\n2. [@7] seven\n8. eight\n9. <CURSOR>nine\n",
  },
  {
    label = "demote sibling at a shallower stray indent (shared parent)",
    op = "list-demote",
    input = "- one\n   - a\n  - <CURSOR>b\n",
  },
  {
    label = "demote normalizes a misindented untouched sibling",
    op = "list-demote",
    input = "- one\n - a\n - <CURSOR>b\n",
  },
  {
    label = "demote refuses on the first item of a (misindented) sub-list",
    op = "list-demote",
    input = "1. one\n  2. <CURSOR>two\n",
    refuse = true,
  },
  {
    label = "demote refuses on the first item of a paragraph-severed run",
    op = "list-demote",
    input = "- parent\n  - one\n\n  para\n  - <CURSOR>uno\n  - dos\n",
    refuse = true,
  },
  {
    label = "demote on the whole list's first item indents the entire list",
    op = "list-demote",
    input = "- <CURSOR>one\n- two\n",
  },
  {
    label = "promote on the whole list's first item outdents the entire list",
    op = "list-promote",
    input = "  - <CURSOR>one\n  - two\n",
  },
  {
    label = "promote refuses on a flush-left top-level first item",
    op = "list-promote",
    input = "- <CURSOR>one\n- two\n",
    refuse = true,
  },
  -- subtree promote (org-shiftmetaleft)
  {
    label = "promote `  - <CURSOR>` -> `- ` (un-indent under root)",
    op = "list-promote",
    input = "- one\n  - <CURSOR>\n- three\n",
  },
  {
    label = "promote nested 4-space indent to 2-space (one level up)",
    op = "list-promote",
    input = "- one\n  - two\n    - <CURSOR>three\n",
  },
  {
    label = "promote ordered sub-item renumbers both levels",
    op = "list-promote",
    input = "1. one\n   1. sub one\n   2. <CURSOR>sub two\n2. two\n",
  },
  {
    label = "promote out of the middle splits the sub-list, both halves renumber",
    op = "list-promote",
    input = "1. one\n   1. a\n   2. <CURSOR>b\n   3. c\n2. two\n",
  },
  {
    label = "promote item with continuation text renumbers the sibling after it",
    op = "list-promote",
    input = "1. one\n   1. a\n   2. <CURSOR>b\n      cont text\n2. two\n",
  },
  {
    label = "promote unordered item into ordered outer list adopts numbering",
    op = "list-promote",
    input = "1. one\n   - <CURSOR>sub\n2. two\n",
  },
  {
    label = "promote item at stray indent lifts it to the outer level",
    op = "list-promote",
    input = "1. one\n  2. <CURSOR>two\n",
  },
  -- item-only variants (org-metaright / org-metaleft)
  {
    label = "item-only demote leaves the child behind as a sibling",
    op = "list-demote-item",
    input = "1. one\n2. <CURSOR>two\n   - child\n",
  },
  {
    label = "item-only promote refuses when the item has children",
    op = "list-promote-item",
    input = "1. one\n   1. a\n   2. <CURSOR>b\n      - child\n2. two\n",
    refuse = true,
  },
  {
    label = "item-only promote of a childless item",
    op = "list-promote-item",
    input = "1. one\n   1. a\n   2. <CURSOR>b\n2. two\n",
  },
  {
    label = "item-only demote refuses at a stray first-child indent",
    op = "list-demote-item",
    input = "1. one\n  2. <CURSOR>two\n",
    refuse = true,
  },
  {
    label = "item-only demote refuses on the whole list's first item",
    op = "list-demote-item",
    input = "- <CURSOR>one\n- two\n",
    refuse = true,
  },
  {
    label = "item-only promote refuses on the whole list's first item",
    op = "list-promote-item",
    input = "  - <CURSOR>one\n  - two\n",
    refuse = true,
  },
}

for _, c in ipairs(cases) do
  run_case(c)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_list_indent_test: PASS")
