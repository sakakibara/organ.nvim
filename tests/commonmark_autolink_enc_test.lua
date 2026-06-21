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

print("commonmark_autolink_enc_test: PASS")
