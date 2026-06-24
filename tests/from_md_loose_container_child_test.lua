-- Regression test: a block quote opening as a second block child of a list item
-- after a blank line loosens the list, like a leaf second child does.  Found by
-- differential fuzzing; verified against cmark-gfm 0.29.0.gfm.13.
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

eq(
  "+ ===\n\n  > x\n",
  "<ul>\n<li>\n<p>===</p>\n<blockquote>\n<p>x</p>\n</blockquote>\n</li>\n</ul>\n",
  "a block quote as a second item child after a blank loosens the list"
)

print("from_md_loose_container_child_test: PASS")
