local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

-- 206: Greek capital def, lowercase reference (Unicode case fold).
assert(
  cmark.render(
    from_md.parse(
      "[\206\145\206\147\206\169]: /\207\134\206\191\207\133\n\n[\206\177\206\179\207\137]\n"
    )
  ) == '<p><a href="/%CF%86%CE%BF%CF%85">\206\177\206\179\207\137</a></p>\n',
  "206 Greek case fold label match"
)
-- 540: capital sharp s reference matches SS def (multi-char full fold).
assert(
  cmark.render(from_md.parse("[\225\186\158]\n\n[SS]: /url\n"))
    == '<p><a href="/url">\225\186\158</a></p>\n',
  "540 sharp-s SS full fold match"
)
-- Non-regression: ASCII case-insensitive label matching still works.
assert(
  cmark.render(from_md.parse("[Foo]\n\n[foo]: /url\n")) == '<p><a href="/url">Foo</a></p>\n',
  "ascii case-insensitive label"
)
assert(
  cmark.render(from_md.parse("[FOO BAR][]\n\n[foo bar]: /url\n"))
    == '<p><a href="/url">FOO BAR</a></p>\n',
  "ascii collapse + case fold"
)
-- A label that should NOT match stays literal.
assert(
  cmark.render(from_md.parse("[bar]\n\n[foo]: /url\n")) == "<p>[bar]</p>\n",
  "non-matching label is literal"
)

print("commonmark_casefold_test: PASS")
