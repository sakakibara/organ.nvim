-- Regression tests for ATX-heading closing-sequence removal in the from_md
-- importer.  A trailing run of '#'s preceded by whitespace is the closing
-- sequence and is removed; a run that is the entire content is also removed; but
-- a '#' left after stripping the closing run is real content.  Found by
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

eq("## ## ## \n", "<h2>##</h2>\n", "only the trailing closing run is stripped, leaving content")
eq("# ## #\n", "<h1>##</h1>\n", "a trailing single # is the closing run")
eq("## # ##\n", "<h2>#</h2>\n", "the closing run leaves a lone # as content")
eq("## ###\n", "<h2></h2>\n", "content that is entirely #s is a closing run (empty heading)")

print("from_md_atx_closing_test: PASS")
