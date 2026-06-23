-- Regression tests for fenced-code-block edge cases in the from_md importer,
-- found by differential fuzzing against cmark-gfm.  Verified against cmark-gfm
-- 0.29.0.gfm.13.
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

-- A fence is a run of a SINGLE char; a closing fence of a different char (the
-- backticks after `~~~`) does not close the tilde fence.
eq(
  "~~~\ncode\n~~~```\n",
  "<pre><code>code\n~~~```\n</code></pre>\n",
  "a mixed `~~~```` line does not close a tilde fence"
)

-- A tilde fence's info string may contain backticks (only a backtick fence
-- forbids them), so the backtick is part of the info, not the fence.
eq(
  "~~~`text\nc\n",
  '<pre><code class="language-`text">c\n</code></pre>\n',
  "a tilde fence info string keeps a leading backtick"
)

-- An unclosed fence keeps its body verbatim, including a trailing blank line;
-- the input's final newline must not synthesise an extra one.
eq(
  "```2.\n\n",
  '<pre><code class="language-2.">\n</code></pre>\n',
  "an unclosed fence keeps one trailing blank line, not zero or two"
)

print("from_md_fenced_code_test: PASS")
