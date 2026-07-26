-- Tests :Org narrow_to_subtree / :Org widen — they delegate to the
-- extracted `narrow.nvim` plugin.  The narrow mechanism itself is
-- exhaustively tested in narrow.nvim's own test suite; here we
-- only verify the integration: organ.structure correctly computes
-- the subtree range and forwards to narrow.to_range, and widen
-- restores via narrow.widen.
--
-- Run via: nvim --headless -l tests/narrow_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.cmd("runtime plugin/organ.lua")

require("organ").setup({})
-- Force conceal mode so the integration test runs in a deterministic
-- mode regardless of headless conceallevel.
require("narrow").setup({ mode = "conceal" })

local cmd = {
  OrgNarrowToSubtree = require("organ").cmd("narrow_to_subtree").fn,
  OrgWiden = require("organ").cmd("widen").fn,
}
local narrow = require("narrow")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function make_buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  return b
end

-- (a) :Org narrow_to_subtree on a top-level headline narrows to that
-- subtree (line 1 through end of section, before the next sibling).
do
  local b = make_buf({
    "* Top level headline",
    "  body of top",
    "** Sub headline",
    "   body of sub",
    "   more body",
    "* Another headline",
    "  body of another",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  cmd.OrgNarrowToSubtree()

  check("narrow active after :Org narrow_to_subtree", narrow.is_narrowed(b))
  local sr, _, er, _ = narrow.region(b)
  check(
    "subtree range = lines 1-5 (rows 0-4 inclusive)",
    sr == 0 and er == 4,
    ("got sr=%s er=%s"):format(tostring(sr), tostring(er))
  )

  cmd.OrgWiden()
  check("widen clears the narrow", not narrow.is_narrowed(b))
  vim.api.nvim_buf_delete(b, { force = true })
end

-- (b) :Org narrow_to_subtree on a sub-headline narrows to just that
-- subtree (not its parent).
do
  local b = make_buf({
    "* Parent",
    "  parent body",
    "** Child",
    "   child body",
    "   more child body",
    "** Another child",
    "   another body",
    "* Sibling of parent",
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- on "** Child"
  cmd.OrgNarrowToSubtree()

  local sr, _, er, _ = narrow.region(b)
  check(
    "sub-headline narrow: rows 2-4 (lines 3-5)",
    sr == 2 and er == 4,
    ("got sr=%s er=%s"):format(tostring(sr), tostring(er))
  )

  cmd.OrgWiden()
  vim.api.nvim_buf_delete(b, { force = true })
end

-- (c) :Org narrow_to_subtree on a non-headline line is a no-op (warns).
do
  local b = make_buf({
    "  this is a body line, no headline",
    "  more body",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  cmd.OrgNarrowToSubtree()
  check("non-headline line: no narrow created", not narrow.is_narrowed(b))
  vim.api.nvim_buf_delete(b, { force = true })
end

-- (d) Narrow + widen cycle is idempotent.
do
  local b = make_buf({
    "* Headline One",
    "  body one",
    "* Headline Two",
    "  body two",
  })
  for i = 1, 3 do
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    cmd.OrgNarrowToSubtree()
    check(("cycle %d: narrowed"):format(i), narrow.is_narrowed(b))
    cmd.OrgWiden()
    check(("cycle %d: widened"):format(i), not narrow.is_narrowed(b))
  end
  vim.api.nvim_buf_delete(b, { force = true })
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("narrow test ok")
