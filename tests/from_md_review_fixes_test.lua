-- Regression tests for issues found in the pre-release audit of the from_md
-- importer (line endings, table-after-reference-definition, and a quadratic
-- nested-bracket hot path).  None of these are exercised by the LF-only
-- conformance fixtures.
local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local from_md = require("organ.ast.from_md")
local cmark = dofile(vim.fn.getcwd() .. "/tests/cmark/html.lua")

local function eq(md, html, msg)
  local got = cmark.render(from_md.parse(md))
  assert(
    got == html,
    msg .. "\n  expected: " .. vim.inspect(html) .. "\n  got:      " .. vim.inspect(got)
  )
end

-- Line endings: CR, LF, and CRLF are all CommonMark line endings.
eq("a\r\nb\r\n", "<p>a\nb</p>\n", "CRLF is a line ending")
eq("a\rb\r", "<p>a\nb</p>\n", "lone CR is a line ending")
eq("```\ncode\r\n```\r\n", "<pre><code>code\n</code></pre>\n", "CRLF stripped in code block")
eq("- a\r\n- b\r\n", "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n", "CRLF in list items")

-- A GFM table is recognized when its header is preceded by reference
-- definitions (the defs are extracted before the lone-header-line check).
eq(
  "[x]: /u\n| a | b |\n| - | - |\n",
  "<table>\n<thead>\n<tr>\n<th>a</th>\n<th>b</th>\n</tr>\n</thead>\n</table>\n",
  "table forms after a leading reference definition"
)
eq("[x]: /u\n\n[x]\n", '<p><a href="/u">x</a></p>\n', "the leading definition is still recorded")

-- Quadratic-on-nested-brackets regression: a deeply nested bracket run must
-- parse in linear time (the reference-label normalize is skipped for over-long
-- labels).  Bounded so an O(n^2) regression fails instead of merely being slow.
do
  local n = 16000
  local input = string.rep("[[", n) .. "x" .. string.rep("]]", n)
  local start = vim.loop.hrtime()
  assert(
    pcall(function()
      return from_md.parse(input)
    end),
    "nested brackets must not throw"
  )
  local ms = (vim.loop.hrtime() - start) / 1e6
  assert(
    ms < 6000,
    string.format("nested brackets parsed in %.0f ms (>6000 ms suggests an O(n^2) regression)", ms)
  )
end

-- Container nesting is bounded, so a pathological single-line marker run parses
-- in linear time, and the produced AST stays shallow enough for the recursive
-- renderers (a deep blockquote no longer overflows the renderer stack).
do
  local start = vim.loop.hrtime()
  assert(
    pcall(function()
      return from_md.parse(string.rep("> - ", 25000) .. "x")
    end),
    "interleaved markers must not throw"
  )
  assert(
    pcall(function()
      return from_md.parse(string.rep("- ", 25000) .. "x")
    end),
    "list markers must not throw"
  )
  local ms = (vim.loop.hrtime() - start) / 1e6
  assert(
    ms < 6000,
    string.format(
      "25000 single-line markers parsed in %.0f ms (>6000 ms suggests an O(n^2) regression)",
      ms
    )
  )
  assert(
    pcall(function()
      return cmark.render(from_md.parse(string.rep("> ", 50000) .. "x\n"))
    end),
    "a deep blockquote must render without overflowing the renderer stack"
  )
end

print("from_md_review_fixes_test: PASS")
