-- Regression tests for GFM list looseness in the from_md importer.  A list is
-- loose when two of its items are separated by a blank line, or an item holds
-- two block-level children separated by one; a blank before an item's first
-- content does not loosen.  The model tracks whether an item has yet received
-- content (`has_content`) so an item whose first block is still open is not
-- mistaken for an empty one.  Found by differential fuzzing; verified against
-- cmark-gfm 0.29.0.gfm.13.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

local function eq(md, html, msg)
  local got = cmark.render(from_md.parse(md))
  assert(
    got == html,
    msg .. "\n  expected: " .. vim.inspect(html) .. "\n  got:      " .. vim.inspect(got)
  )
end

-- A blank before an item's first content keeps the list tight.
eq("- \n\t\n  x\n", "<ul>\n<li>x</li>\n</ul>\n", "a blank before first content does not loosen")

-- A blank between an item's two block children loosens the list.
eq(
  "- a\n\n  b\n",
  "<ul>\n<li>\n<p>a</p>\n<p>b</p>\n</li>\n</ul>\n",
  "a blank between an item's two blocks loosens the list"
)

-- The item's first block may still be open (a paragraph) when the blank lands;
-- the following indented block is still a second child, so the list is loose.
eq(
  "- \n  c\nx\n\n    code\n",
  "<ul>\n<li>\n<p>c\nx</p>\n<p>code</p>\n</li>\n</ul>\n",
  "an open first block still counts as content for looseness"
)

-- A blank between two items loosens the list.
eq(
  "- a\n\n- b\n",
  "<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n",
  "a blank between two items loosens the list"
)

print("from_md_list_looseness_test: PASS")
