-- Regression tests for emphasis flanking next to a strikethrough tilde.  cmark
-- registers `~` as an emphasis delimiter, so it is skipped when finding the
-- character before/after a `*`/`_` run: a `~` adjacent to a run makes the
-- neighbour the first non-`~` character.  Found by differential fuzzing against
-- cmark-gfm 0.29.0.gfm.13 (with the strikethrough extension).
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

-- The closing `_` is followed by `~`; skipping it leaves `x`, so the `_` sits
-- between two word characters and cannot close -- no emphasis.
eq("_a_~x\n", "<p>_a_~x</p>\n", "a tilde after a `_` run suppresses intraword emphasis")

-- The closing `*` is preceded by `~~`; skipping leaves a space, so the run is
-- not right-flanking and cannot close.
eq("a*b ~~*(\n", "<p>a*b ~~*(</p>\n", "a tilde run before a `*` run suppresses closing")

eq("_~a_~a\n", "<p>_~a_~a</p>\n", "tildes around a `_` run suppress emphasis")

print("from_md_emphasis_tilde_flank_test: PASS")
