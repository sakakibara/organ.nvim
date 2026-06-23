-- Regression test for a tab preceding a list marker in the from_md importer.
-- The leading indentation before a list marker is measured in COLUMNS, so a tab
-- (column-expanded from the current base) can supply it.  Found by differential
-- fuzzing; verified against cmark-gfm 0.29.0.gfm.13.
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

-- After `> ` the base column is 2; the tab expands to column 4 (two columns),
-- which is <= 3 leading columns, so `+ x` starts a list inside the quote.
eq(
  "> \t+ x\n",
  "<blockquote>\n<ul>\n<li>x</li>\n</ul>\n</blockquote>\n",
  "a tab after a block-quote marker indents a list marker"
)

print("from_md_list_tab_test: PASS")
