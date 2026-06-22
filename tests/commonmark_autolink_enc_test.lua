local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

-- Example 20: backslash in angle autolink URI -> %5C (autolinks do NOT decode escapes).
assert(
  cmark.render(from_md.parse("<https://example.com?find=\\*>\n"))
    == '<p><a href="https://example.com?find=%5C*">https://example.com?find=\\*</a></p>\n',
  "example 20: backslash in autolink href is percent-encoded"
)

-- Example 346: backtick inside angle autolink URI -> %60; trailing backtick is literal.
assert(
  cmark.render(from_md.parse("<https://foo.bar.`baz>`\n"))
    == '<p><a href="https://foo.bar.%60baz">https://foo.bar.`baz</a>`</p>\n',
  "example 346: backtick in autolink href is percent-encoded"
)

-- Example 526: ] in autolink URI is percent-encoded -> %5D.
assert(
  cmark.render(from_md.parse("[foo<https://example.com/?search=](uri)>\n"))
    == '<p>[foo<a href="https://example.com/?search=%5D(uri)">https://example.com/?search=](uri)</a></p>\n',
  "example 526: ] in autolink href is percent-encoded"
)

-- Example 538: ] and [ in autolink URI -> %5D and %5B.
assert(
  cmark.render(from_md.parse("[foo<https://example.com/?search=][ref]>\n\n[ref]: /uri\n"))
    == '<p>[foo<a href="https://example.com/?search=%5D%5Bref%5D">https://example.com/?search=][ref]</a></p>\n',
  "example 538: ] and [ in autolink href are percent-encoded"
)

-- Example 603: backslash and [ in autolink URI -> %5C and %5B.
assert(
  cmark.render(from_md.parse("<https://example.com/\\[\\>\n"))
    == '<p><a href="https://example.com/%5C%5B%5C">https://example.com/\\[\\</a></p>\n',
  "example 603: backslash and [ in autolink href are percent-encoded"
)

-- Non-regression: a clean autolink URI is unchanged (percent-encoding is a no-op on safe bytes).
assert(
  cmark.render(from_md.parse("<http://foo.bar.baz>\n"))
    == '<p><a href="http://foo.bar.baz">http://foo.bar.baz</a></p>\n',
  "clean autolink unchanged"
)

-- Non-regression: a regular link destination with a backslash escape still decodes then encodes.
assert(
  cmark.render(from_md.parse("[a](/b\\*c)\n")) == '<p><a href="/b*c">a</a></p>\n',
  "regular dest decodes escape"
)

-- GFM extended autolinks are detected on the RAW source, so a character
-- reference behaves the way cmark-gfm (what GitHub renders) treats it: a
-- trailing reference is excluded from the link; an in-URL reference stays raw.
-- Expected values verified against cmark-gfm 0.29.0.gfm.13.
local A = { extended_autolinks = true }
assert(
  cmark.render(from_md.parse("www.x.com/a&amp;\n", A))
    == '<p><a href="http://www.x.com/a">www.x.com/a</a>&amp;</p>\n',
  "trailing &amp; is excluded from an extended autolink"
)
assert(
  cmark.render(from_md.parse("www.x.com/a&copy;b\n", A))
    == '<p><a href="http://www.x.com/a&amp;copy;b">www.x.com/a&amp;copy;b</a></p>\n',
  "an in-URL reference stays raw in the link"
)
assert(
  cmark.render(from_md.parse("www.x.com/a&amp;b\n", A))
    == '<p><a href="http://www.x.com/a&amp;amp;b">www.x.com/a&amp;amp;b</a></p>\n',
  "an in-URL &amp; stays raw"
)
assert(
  cmark.render(from_md.parse("www.x.com/a;\n", A))
    == '<p><a href="http://www.x.com/a">www.x.com/a</a>;</p>\n',
  "a bare trailing semicolon is excluded"
)
assert(
  cmark.render(from_md.parse("www.x.com/a&#38;\n", A))
    == '<p><a href="http://www.x.com/a&amp;#38">www.x.com/a&amp;#38</a>;</p>\n',
  "a numeric reference is not an &alpha+; entity: only its semicolon is excluded"
)
-- A literal `&amp;` produced by an escaped ampersand is NOT a reference and must
-- not be decoded by the autolink pass (the escaped & is its own segment).
assert(
  cmark.render(from_md.parse("\\&amp;\n", A)) == "<p>&amp;amp;</p>\n",
  "an escaped ampersand spelling out a reference is not decoded"
)
assert(
  cmark.render(from_md.parse("a\\&amp;b\n", A)) == "<p>a&amp;amp;b</p>\n",
  "a literal &amp; between text is left raw"
)

print("commonmark_autolink_enc_test: PASS")
