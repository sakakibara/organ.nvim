-- Regression test: a tab may indent a nested block-quote marker.  The marker's
-- leading indentation is measured in columns (a tab column-expands), so the `\t`
-- after a `> ` marker (two columns, <= 3) introduces a nested `>`.  Found by
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
  "> \t> x\n",
  "<blockquote>\n<blockquote>\n<p>x</p>\n</blockquote>\n</blockquote>\n",
  "a tab indents a nested block-quote marker"
)

print("from_md_blockquote_tab_test: PASS")
