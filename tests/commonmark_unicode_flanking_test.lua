local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

local NBSP = "\194\160" -- U+00A0
assert(
  cmark.render(from_md.parse("*" .. NBSP .. "a" .. NBSP .. "*\n"))
    == "<p>*" .. NBSP .. "a" .. NBSP .. "*</p>\n",
  "353 nbsp around * is whitespace, no emphasis"
)
assert(
  cmark.render(from_md.parse("*$*alpha.\n")) == "<p>*$*alpha.</p>\n",
  "354a $ is punctuation, no emphasis"
)
assert(
  cmark.render(from_md.parse("*\194\163*bravo.\n")) == "<p>*\194\163*bravo.</p>\n",
  "354b pound sign is Unicode punctuation, no emphasis"
)
assert(
  cmark.render(from_md.parse("*\226\130\172*charlie.\n")) == "<p>*\226\130\172*charlie.</p>\n",
  "354c euro sign is Unicode punctuation, no emphasis"
)
-- Non-regression: ASCII emphasis unchanged; a letter adjacent still flanks.
assert(
  cmark.render(from_md.parse("*foo*\n")) == "<p><em>foo</em></p>\n",
  "ascii emphasis still works"
)
assert(
  cmark.render(from_md.parse("**bold**\n")) == "<p><strong>bold</strong></p>\n",
  "ascii strong still works"
)
assert(
  cmark.render(from_md.parse("a*foo*b\n")) == "<p>a<em>foo</em>b</p>\n",
  "intraword * emphasis"
)
-- A letter-adjacent multibyte char does not block flanking (e-acute is not ws/punct).
assert(
  cmark.render(from_md.parse("*\195\169*\n")) == "<p><em>\195\169</em></p>\n",
  "emphasis around a letter (e-acute)"
)

print("commonmark_unicode_flanking_test: PASS")
