-- Verifies organ.export.html converts org → HTML5.
-- Run via: nvim --headless -l tests/export_html_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local p = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = p })

local html = require("organ.export.html")

local function assert_contains(haystack, needle, msg)
  assert(
    haystack:find(needle, 1, true),
    (msg or "expected to find") .. ": '" .. needle .. "' in:\n" .. haystack
  )
end

-- 1. Headlines map to <h1>/<h2>/<h3>.
do
  local out = html.export([[
* Top
** Sub
*** Deep
]])
  assert_contains(out, '<h1 id="top">Top</h1>')
  assert_contains(out, '<h2 id="sub">Sub</h2>')
  assert_contains(out, '<h3 id="deep">Deep</h3>')
end

-- 2. Title pulled from #+title.
do
  local out = html.export([[
#+title: My Doc
* Heading
]])
  assert_contains(out, "<title>My Doc</title>")
end

-- 3. Bold / italic / verbatim / link.
do
  local out = html.export([==[
* H
This is *bold* and =verb= and [[https://example.com][a link]].
]==])
  assert_contains(out, "<strong>bold</strong>")
  assert_contains(out, "<code>verb</code>")
  assert_contains(out, '<a href="https://example.com">a link</a>')
end

-- 4. Source block uses <pre><code class="language-X">.
do
  local out = html.export([[
* H
#+begin_src python
print("hi")
#+end_src
]])
  assert_contains(out, '<pre><code class="language-python">')
  assert_contains(out, "print(&quot;hi&quot;)")
end

-- 5. List with checkboxes uses <input type="checkbox">.
do
  local out = html.export([[
* H
- [ ] todo
- [X] done
]])
  assert_contains(out, '<input type="checkbox" disabled')
  assert_contains(out, '<input type="checkbox" checked disabled')
end

-- 6. Table with header divider produces <thead>/<tbody>.
do
  local out = html.export([[
* H
| name | age |
|------+-----|
| ada  |  36 |
]])
  assert_contains(out, "<table>")
  assert_contains(out, "<thead>")
  assert_contains(out, "<th>name</th>")
  assert_contains(out, "<tbody>")
  assert_contains(out, "<td>ada</td>")
end

-- 7. HTML escaping.
do
  local out = html.export([[
* H
<script>alert(1)</script>
]])
  assert_contains(out, "&lt;script&gt;alert(1)&lt;/script&gt;")
  assert(not out:find("<script>alert", 1, true), "script tag must be escaped:\n" .. out)
end

-- 8. minimal_style = false drops the inline <style> block.
do
  local out = html.export("* H\n", { minimal_style = false })
  assert(not out:find("<style>", 1, true), "style block must be omitted")
end

io.write("export html ok\n")
os.exit(0)
