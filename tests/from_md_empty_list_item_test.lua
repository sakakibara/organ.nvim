-- Regression tests for an empty list item (begun with a blank line) followed by
-- a blank line and then content, in the from_md importer.  An interior blank
-- line indented to the item's content column keeps the item open; a blank that
-- falls short of it seals the empty item ("a list item can begin with at most
-- one blank line").  Found by differential fuzzing; verified against cmark-gfm
-- 0.29.0.gfm.13.
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

-- A tab-only line is 4 columns >= the item's content indent (2), so it is an
-- interior blank and the deeply-indented content stays in the item.
eq(
  "- \n\t\n        x\n",
  "<ul>\n<li>\n<pre><code>  x\n</code></pre>\n</li>\n</ul>\n",
  "a tab-indented blank keeps the empty item open"
)

-- Two spaces reach the content column too (same outcome).
eq(
  "- \n  \n        x\n",
  "<ul>\n<li>\n<pre><code>  x\n</code></pre>\n</li>\n</ul>\n",
  "a two-space blank reaches the content column and keeps the item open"
)

-- A truly empty (zero-column) blank seals the empty item; the content is not
-- part of it.
eq("- \n\n  x\n", "<ul>\n<li></li>\n</ul>\n<p>x</p>\n", "a zero-column blank seals the empty item")

print("from_md_empty_list_item_test: PASS")
