-- Regression tests for trailing-whitespace handling at a line ending in the
-- from_md inline parser.  CommonMark drops trailing spaces AND tabs before a
-- soft break, and before a hard break (the 2+ spaces plus any tab before them).
-- Found by differential fuzzing; verified against cmark-gfm 0.29.0.gfm.13.
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

-- A trailing tab before a soft break is stripped (it is not two spaces, so not
-- a hard break).
eq("a\t\nb\n", "<p>a\nb</p>\n", "a trailing tab is stripped before a soft break")

-- A tab before the two hard-break spaces is also dropped.
eq("a\t  \nb\n", "<p>a<br />\nb</p>\n", "a tab before hard-break spaces is dropped")

print("from_md_trailing_ws_test: PASS")
