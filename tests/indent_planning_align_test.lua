-- Regression: in virtual indent-mode, lines that carry organ's adaptive
-- `planning_indent` real whitespace (planning lines DEADLINE/SCHEDULED/CLOSED
-- and drawers) must render at the SAME column as the heading title text --
-- the inline pad absorbs their real indent instead of stacking on top of it
-- (which pushed them `planning_indent` columns past the title).
--
-- Structural indentation must be PRESERVED: a nested list item keeps its real
-- nesting on top of the uniform pad (matching Emacs org-indent), and this
-- holds at any shift_per_level since content always aligns with the title.
-- Run via: nvim --headless -l tests/indent_planning_align_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local indent = require("organ.indent")

-- Visual first-byte column (inline virtual pad + real leading whitespace)
-- for every row, plus the heading's own virtual pad.
local function columns_for_shift(shift)
  require("organ").setup({ indent = { enabled = true, shift_per_level = shift } })
  local f = "/tmp/indent_align_" .. shift .. ".org"
  -- Planning + drawer lines carry level+1 (=3) real spaces, as
  -- planning_indent="adapt" produces under a level-2 heading.  The nested
  -- list item carries 2 real spaces of structural nesting.
  vim.fn.writefile({
    "* Top",
    "** H2",
    "   DEADLINE: <2026-06-21 Sun>",
    "   :PROPERTIES:",
    "   :ID: abc-123",
    "   :END:",
    "- top item",
    "  - nested item",
    "Body paragraph.",
  }, f)
  local b = vim.fn.bufadd(f)
  vim.fn.bufload(b)
  vim.bo[b].filetype = "org"
  indent._attached[b] = nil
  indent.attach(b)
  indent.refresh(b)

  local vpad = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, { details = true })) do
    vpad[m[2]] = (m[4].virt_text and #m[4].virt_text[1][1]) or 0
  end
  local cols = {}
  for i, txt in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    cols[i] = (vpad[i - 1] or 0) + #(txt:match("^(%s*)") or "")
  end
  return cols, vpad
end

for _, shift in ipairs({ 1, 2 }) do
  local cols, vpad = columns_for_shift(shift)
  -- H2 is line 2, level 2; its title starts after the heading pad + 2 stars
  -- + 1 space.
  local title_col = (vpad[1] or 0) + 2 + 1

  local aligned = {
    { 3, "DEADLINE (planning)" },
    { 4, ":PROPERTIES: (drawer open)" },
    { 5, ":ID: (drawer interior)" },
    { 6, ":END: (drawer close)" },
    { 7, "top-level list item" },
    { 9, "body paragraph" },
  }
  for _, a in ipairs(aligned) do
    assert(
      cols[a[1]] == title_col,
      string.format("shift=%d: %s col %d != title col %d", shift, a[2], cols[a[1]], title_col)
    )
  end

  -- The nested list item keeps its 2-space structural nesting ON TOP of the
  -- uniform pad -- it must NOT be flattened onto the title column.
  assert(
    cols[8] == title_col + 2,
    string.format("shift=%d: nested list col %d != title+2 (%d)", shift, cols[8], title_col + 2)
  )
end

print("indent_planning_align_test: PASS")
