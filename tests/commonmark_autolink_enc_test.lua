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

-- Extended-autolink detection rules, all verified against cmark-gfm
-- 0.29.0.gfm.13 (the renderer GitHub uses).
local function eq_ext(md, html, msg)
  assert(
    cmark.render(from_md.parse(md, A)) == html,
    msg
      .. "\n  expected: "
      .. vim.inspect(html)
      .. "\n  got:      "
      .. vim.inspect(cmark.render(from_md.parse(md, A)))
  )
end

-- A scheme URL needs no period in its host (cmark's check_domain allows a short
-- domain after `://`), and may carry userinfo before the host.
eq_ext(
  "http://localhost\n",
  '<p><a href="http://localhost">http://localhost</a></p>\n',
  "scheme host needs no dot"
)
eq_ext(
  "http://foo@bar.com\n",
  '<p><a href="http://foo@bar.com">http://foo@bar.com</a></p>\n',
  "scheme userinfo stays in the link"
)
eq_ext("ftp://x\n", '<p><a href="ftp://x">ftp://x</a></p>\n', "ftp scheme, short host")

-- A www. prefix is case-sensitive (cmark uses memcmp); a domain needs a period.
eq_ext("WWW.example.com\n", "<p>WWW.example.com</p>\n", "uppercase WWW. is not a www autolink")

-- A `mailto:`/`xmpp:` scheme is kept in the link text instead of an inserted
-- mailto: href; an email may begin after any non-local-part character.
eq_ext(
  "mailto:foo@bar.com\n",
  '<p><a href="mailto:foo@bar.com">mailto:foo@bar.com</a></p>\n',
  "mailto: scheme kept"
)
eq_ext("xmpp:a@b.com\n", '<p><a href="xmpp:a@b.com">xmpp:a@b.com</a></p>\n', "xmpp: scheme kept")
eq_ext(
  "see:foo@bar.com\n",
  '<p>see:<a href="mailto:foo@bar.com">foo@bar.com</a></p>\n',
  "email recognised after a colon"
)

-- A bracket-enclosed run is not scanned for www/scheme autolinks (cmark's
-- in_bracket check); a `]`/`[` inside a link href is percent-encoded.
eq_ext("[a http://x.io]\n", "<p>[a http://x.io]</p>\n", "no scheme autolink inside brackets")
eq_ext(
  "www.x.com/a]b\n",
  '<p><a href="http://www.x.com/a%5Db">www.x.com/a]b</a></p>\n',
  "a `]` in the href is %5D"
)

-- Extended autolinks are matched during the inline parse, on the raw line,
-- before backslash escapes are decoded and emphasis is resolved (cmark matches
-- www/url inline; only emails are a postprocess pass).  Three consequences:

-- A backslash inside a URL is a literal URL byte, kept in the text and
-- percent-encoded (%5C) in the href -- it is not an escape.
eq_ext(
  "www.x.com/a\\*b\n",
  '<p><a href="http://www.x.com/a%5C*b">www.x.com/a\\*b</a></p>\n',
  "a backslash in a URL is literal (href %5C)"
)

-- An emphasis run can wrap an autolink, but `__`/`_ ` adjacent to a domain are
-- domain bytes at match time: cmark's check_domain ignores only the very last
-- byte, so a doubled or non-final trailing underscore invalidates the domain
-- and the URL is not linked.
eq_ext(
  "*www.x.com*\n",
  '<p><em><a href="http://www.x.com">www.x.com</a></em></p>\n',
  "emphasis wraps an autolink"
)
eq_ext(
  "__www.foo.com__\n",
  "<p><strong>www.foo.com</strong></p>\n",
  "a trailing __ invalidates the domain"
)
eq_ext(
  "a _www.foo.com_ b\n",
  "<p>a <em>www.foo.com</em> b</p>\n",
  "a non-final trailing _ invalidates the domain"
)

-- Trailing spaces/tabs on the final line are stripped before matching (so a
-- bare `www.` is not a one-segment domain).
eq_ext("www. \n", "<p>www.</p>\n", "trailing space is stripped before the autolink scan")

print("commonmark_autolink_enc_test: PASS")
