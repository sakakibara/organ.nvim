-- Regression tests: a tab worth <= 3 columns of indentation precedes a block
-- start (ATX heading, setext underline, thematic break).  The recognisers
-- measure indentation as literal spaces, so a tab left by a container marker was
-- missed.  Found by differential fuzzing; verified against cmark-gfm
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

-- After `> ` the base is column 2, so the tab is two columns (<= 3): an ATX
-- heading, a setext underline, and a thematic break are all recognised.
eq(
  "> \t## \n",
  "<blockquote>\n<h2></h2>\n</blockquote>\n",
  "a tab before an ATX heading in a quote"
)
eq(
  "> x\n> \t---\n",
  "<blockquote>\n<h2>x</h2>\n</blockquote>\n",
  "a tab before a setext underline in a quote"
)
eq("> \t***\n", "<blockquote>\n<hr />\n</blockquote>\n", "a tab before a thematic break in a quote")

print("from_md_tab_block_start_test: PASS")
