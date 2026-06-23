-- Regression tests for lazy paragraph continuation across a block-quote
-- boundary in the from_md importer.  A block that "cannot interrupt a paragraph"
-- (an empty or non-1-start list, a type-7 HTML block) is only blocked when the
-- paragraph is directly in the matched container; reached only by lazy
-- continuation, the paragraph is in a deeper, unmatched container, so the block
-- opens at the outer level and ends the quote.  Indented code is the exception:
-- it stays lazy continuation.  Verified against cmark-gfm 0.29.0.gfm.13.
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

-- An empty bullet after a quoted paragraph ends the quote and starts a list (it
-- cannot interrupt the paragraph in its own container, but here it opens one
-- level out).
eq(
  "> text\n- \n",
  "<blockquote>\n<p>text</p>\n</blockquote>\n<ul>\n<li></li>\n</ul>\n",
  "an empty bullet ends the quote and starts a list"
)

-- A non-1-start ordered list likewise ends the quote (it could not interrupt a
-- paragraph in the same container).
eq(
  "> text\n2. x\n",
  '<blockquote>\n<p>text</p>\n</blockquote>\n<ol start="2">\n<li>x</li>\n</ol>\n',
  "a non-1 ordered list ends the quote"
)

-- A type-7 HTML block ends the quote (it cannot interrupt a paragraph directly).
eq(
  "> text\n<x>\n",
  "<blockquote>\n<p>text</p>\n</blockquote>\n<x>\n",
  "a type-7 HTML block ends the quote"
)

-- Indented code does NOT end the quote: it stays lazy paragraph continuation.
eq(
  "> text\n    code\n",
  "<blockquote>\n<p>text\ncode</p>\n</blockquote>\n",
  "indented code lazily continues the quoted paragraph"
)

-- A bullet WITH content already interrupts (non-regression), as does start-1.
eq(
  "> text\n- x\n",
  "<blockquote>\n<p>text</p>\n</blockquote>\n<ul>\n<li>x</li>\n</ul>\n",
  "a non-empty bullet ends the quote"
)

print("from_md_lazy_continuation_test: PASS")
