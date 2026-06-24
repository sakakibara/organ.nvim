-- Regression test: a blank line of fenced-code content inside a list item keeps
-- the indentation beyond the item's content column.  The item-continuation used
-- to collapse any blank line to empty, dropping that whitespace.  Found by
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

-- The fence is at the item's content column (2); the tab line is 4 columns, so
-- stripping the 2-column item indent leaves a two-space code line.
eq(
  "+ ~~~\n\t\na\n",
  "<ul>\n<li>\n<pre><code>  \n</code></pre>\n</li>\n</ul>\n<p>a</p>\n",
  "a blank fenced-code line in an item keeps its over-indent"
)

print("from_md_list_fenced_blank_test: PASS")
