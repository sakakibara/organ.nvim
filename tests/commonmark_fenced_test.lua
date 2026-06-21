local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local cmark = dofile(root .. "/tests/cmark/html.lua")

-- Example 24: backslash escape in info string (foo\+bar -> foo+bar).
assert(
  cmark.render(from_md.parse("``` foo\\+bar\nfoo\n```\n"))
    == '<pre><code class="language-foo+bar">foo\n</code></pre>\n',
  "ex24 backslash escape in info string"
)

-- Example 34: entity references in info string (f&ouml;&ouml; -> foeoe with umlauts).
assert(
  cmark.render(from_md.parse("``` f&ouml;&ouml;\nfoo\n```\n"))
    == '<pre><code class="language-f\xC3\xB6\xC3\xB6">foo\n</code></pre>\n',
  "ex34 entity ref in info string"
)

-- Example 133: fence indented 3 spaces; body strips up to 3 leading spaces.
assert(
  cmark.render(from_md.parse("   ```\n   aaa\n    aaa\n  aaa\n   ```\n"))
    == "<pre><code>aaa\n aaa\naaa\n</code></pre>\n",
  "ex133 up-to-N indent strip from fenced body"
)

-- Non-regression: a plain info string is unchanged.
assert(
  cmark.render(from_md.parse("```ruby\nx\n```\n"))
    == '<pre><code class="language-ruby">x\n</code></pre>\n',
  "plain info string"
)

-- Non-regression: only the first word is the language; the body is verbatim.
assert(
  cmark.render(from_md.parse("``` ruby startline=3\nx\\+y\n```\n"))
    == '<pre><code class="language-ruby">x\\+y\n</code></pre>\n',
  "first word only, body verbatim"
)

-- Non-regression: a non-indented fence keeps body indentation verbatim.
assert(
  cmark.render(from_md.parse("```\n  indented\n```\n")) == "<pre><code>  indented\n</code></pre>\n",
  "no fence indent, body kept"
)

print("commonmark_fenced_test: PASS")
