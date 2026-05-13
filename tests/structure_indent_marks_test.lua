-- Regression: rewrite_stars on a headline must not disturb inline
-- extmarks placed at column 0 of NEIGHBORING rows.  org-indent-mode
-- places one such mark per body row to pad the row to its enclosing
-- headline's title column; `nvim_buf_set_lines` with a 1->1
-- replacement pulls those col-0 marks from row+1 onto the changed
-- row, surfacing for the user as a one-frame "all lines flushed to
-- left" flicker on promote / demote.  Switching rewrite_stars to a
-- surgical `nvim_buf_set_text` at column 0 leaves neighbor marks
-- alone.
--
-- Run via: nvim --headless -l tests/structure_indent_marks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local structure = require("organ.structure")

local b = vim.api.nvim_create_buf(false, true)
vim.bo[b].filetype = "org"
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1", -- row 0
  "Body H1", -- row 1
  "** H2", -- row 2
  "Body H2", -- row 3
  "*** H3", -- row 4
  "Body H3", -- row 5
})

-- Place a distinct inline-virt-text mark at col 0 of every row (the
-- minimal stand-in for org-indent-mode's per-row pad mark).
local ns = vim.api.nvim_create_namespace("structure_indent_marks_test")
for r = 0, 5 do
  vim.api.nvim_buf_set_extmark(b, ns, r, 0, {
    virt_text = { { "<" .. r .. ">", "Comment" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

local function row_to_tag()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
    -- m[2] = row; m[4].virt_text[1][1] = tag string ("<N>").
    out[#out + 1] = { row = m[2], tag = m[4].virt_text[1][1] }
  end
  return out
end

local function expect_one_mark_per_row(label)
  local rows = row_to_tag()
  local seen = {}
  for _, e in ipairs(rows) do
    if seen[e.row] then
      error(
        label
          .. ": expected one mark per row, found duplicate on row "
          .. e.row
          .. " (tags "
          .. seen[e.row]
          .. " + "
          .. e.tag
          .. ")"
      )
    end
    seen[e.row] = e.tag
    if e.tag ~= "<" .. e.row .. ">" then
      error(label .. ": row " .. e.row .. " has tag " .. e.tag .. " (mark migrated)")
    end
  end
end

expect_one_mark_per_row("before any edit")

-- Demote headline at row 2 (** H2 -> *** H2).  Before the fix, this
-- pulled the col-0 mark from row 3 (body) onto row 2 (heading).
structure.demote_headline({ bufnr = b, line = 3 })
expect_one_mark_per_row("after demote_headline on H2")

-- Promote headline at row 4 (*** H3 -> ** H3).
structure.promote_headline({ bufnr = b, line = 5 })
expect_one_mark_per_row("after promote_headline on H3")

-- Subtree demote on H1: rewrites every heading row under the subtree.
structure.demote_subtree({ bufnr = b, line = 1 })
expect_one_mark_per_row("after demote_subtree on H1")

-- Subtree promote on the (now-deeper) H1: brings every heading back.
structure.promote_subtree({ bufnr = b, line = 1 })
expect_one_mark_per_row("after promote_subtree on H1")

io.write("structure indent marks ok\n")
os.exit(0)
