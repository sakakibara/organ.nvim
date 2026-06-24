-- Regression tests: a blank line adjacent to a thematic break or heading does
-- not loosen a list (cmark excepts those from its last-line-blank flag).  Found
-- by differential fuzzing; verified against cmark-gfm 0.29.0.gfm.13.
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

-- A thematic-break item followed by a blank and another item stays tight.
eq(
  "- ___\n\n- x\n",
  "<ul>\n<li>\n<hr />\n</li>\n<li>x</li>\n</ul>\n",
  "a blank after a thematic-break item does not loosen"
)

-- A blank between a thematic break and the next block of the same item stays
-- tight.
eq(
  "- a\n  ___\n\n  b\n",
  "<ul>\n<li>a\n<hr />\nb</li>\n</ul>\n",
  "a blank after a thematic break inside an item does not loosen"
)

-- A heading is NOT exempt: a blank after one loosens like any other block.
eq(
  "- # h\n\n  x\n",
  "<ul>\n<li>\n<h1>h</h1>\n<p>x</p>\n</li>\n</ul>\n",
  "a blank after a heading inside an item loosens"
)
eq(
  "- # h\n\n- y\n",
  "<ul>\n<li>\n<h1>h</h1>\n</li>\n<li>\n<p>y</p>\n</li>\n</ul>\n",
  "a blank after a heading item loosens"
)

-- Sanity: two paragraph items separated by a blank are still loose.
eq(
  "- x\n\n- y\n",
  "<ul>\n<li>\n<p>x</p>\n</li>\n<li>\n<p>y</p>\n</li>\n</ul>\n",
  "a blank between two paragraph items still loosens"
)

print("from_md_looseness_rule_test: PASS")
