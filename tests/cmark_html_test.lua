local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local from_md = require("organ.ast.from_md")
local cmark_html = dofile(root .. "/tests/cmark/html.lua")

local function html(md)
  return cmark_html.render(from_md.parse(md))
end

assert(html("hello\n") == "<p>hello</p>\n", "single paragraph -> <p>")
assert(html("a\n\nb\n") == "<p>a</p>\n<p>b</p>\n", "two paragraphs")
-- HTML metacharacters are escaped per the CommonMark reference.
assert(html("1 < 2 & 3 > 0\n") == "<p>1 &lt; 2 &amp; 3 &gt; 0</p>\n", "escaping")
assert(html("") == "", "empty document -> empty string")

print("cmark_html_test: PASS")
