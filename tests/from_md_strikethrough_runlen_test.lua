-- Regression tests for GFM strikethrough delimiter run length in the from_md
-- importer.  Only a run of one or two tildes is a strikethrough delimiter; a run
-- of three or more is literal text.  Found by differential fuzzing; verified
-- against cmark-gfm 0.29.0.gfm.13.
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

-- A three-tilde run is not a strikethrough delimiter (the leading `_` keeps the
-- line from being a tilde code fence).
eq("_~~~a~~~\n", "<p>_~~~a~~~</p>\n", "a three-tilde run is literal, not strikethrough")

-- One and two tildes still strike through (non-regression).
eq("a ~b~ c\n", "<p>a <del>b</del> c</p>\n", "a single tilde strikes through")
eq("a ~~b~~ c\n", "<p>a <del>b</del> c</p>\n", "a double tilde strikes through")

print("from_md_strikethrough_runlen_test: PASS")
