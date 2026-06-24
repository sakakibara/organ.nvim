-- Regression test: trailing blank lines of an indented code block are removed
-- even when they had whitespace beyond the 4-column strip (so they survive as
-- residual spaces).  Found by differential fuzzing; verified against cmark-gfm
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

-- The 6-space trailing line is blank; it leaves "  " after the 4-column strip,
-- and that residual line is dropped too.
eq(
  "    a\n      \n",
  "<pre><code>a\n</code></pre>\n",
  "a trailing whitespace-only code line is dropped, residual spaces and all"
)

print("from_md_indented_code_trailing_test: PASS")
