-- Regression tests for emphasis/strikethrough delimiter resolution in deeply
-- unbalanced "delimiter soup".  These exercise three rules where organ once
-- over-paired delimiters that cmark-gfm leaves literal.  Found by differential
-- fuzzing; every expected string is byte-verified against cmark-gfm
-- 0.29.0.gfm.13 (with the strikethrough extension; none of these inputs hit the
-- nested-strong rendering artifact, so the raw HTML matches the oracle as-is).
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

-- A `~~` closer first binds to the nearest same-char opener regardless of run
-- length.  Here the lone interior `~` is that nearest opener; the length
-- mismatch then drops both delimiters (cmark's strikethrough `insert` consumes
-- opener..closer without emitting), which is exactly what stops the outer `~~`
-- pair from striking through.  Everything stays literal.
eq(
  "~___~~;/~foo~~)\n",
  "<p>~___~~;/~foo~~)</p>\n",
  "a nearer unequal-length tilde opener burns the closer, leaving tildes literal"
)

-- openers_bottom is keyed by (char, original-length-class) only -- no can_open
-- axis -- and a failed closer raises the floor for every later closer of that
-- key.  The `*` between the x's fails to find an opener and walls off the
-- leading `**`, so the trailing `****` can only reach that `*`, never the `**`.
eq(
  "**x*x****\n",
  "<p>**x<em>x</em>***</p>\n",
  "a failed inner closer walls off the leading ** from the trailing run"
)

-- The floor is keyed by the closer's ORIGINAL run length, which never shrinks as
-- the closer is partially consumed -- so a `****` that spends two chars on an
-- inner em keeps the floor of its length-4 bucket and cannot drop down to an
-- earlier opener.
eq(
  "**_*___*\n",
  "<p>**<em>*</em>__*</p>\n",
  "a partially-consumed closer keeps its original-length floor"
)
eq("_*__***__\n", "<p>_<em>__</em>**__</p>\n", "original-length floor, underscore variant")

-- The floor is a stable position, not a node reference: when the barrier-setting
-- closer is later removed (consumed as content between a matched pair), a removed
-- node could no longer enforce the floor, but a position still does.
eq("__*_***_\n", "<p>__<em>_</em>**_</p>\n", "a removed barrier delimiter still bounds the scan")
eq("*_**___**\n", "<p>*<em>**</em>__**</p>\n", "position floor survives barrier removal")
eq("**_y*y_*\n", "<p>**<em>y*y</em>*</p>\n", "position floor with interior text")

print("from_md_emphasis_soup_test: PASS")
