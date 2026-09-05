-- Unit tests for organ.ast.to_html.  Build AST nodes via organ.ast
-- builders, render to HTML string, assert via substring matches.
--
-- Run via: nvim --headless -l tests/ast_to_html_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local A = require("organ.ast")
local to_html = require("organ.ast.to_html")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Empty document
do
  local out = to_html.render(A.document({}))
  check("DOCTYPE present", out:find("<!DOCTYPE html>", 1, true) ~= nil, "got: " .. out)
  check("html lang=en present", out:find('<html lang="en">', 1, true) ~= nil)
  check("default title is Untitled", out:find("<title>Untitled</title>", 1, true) ~= nil)
  check("body present", out:find("<body>", 1, true) ~= nil)
end

-- Title from TITLE directive
do
  local doc = A.document({
    A.directive("TITLE", "My Doc"),
    A.paragraph({ A.text("body") }),
  })
  local out = to_html.render(doc)
  check(
    "title from TITLE directive",
    out:find("<title>My Doc</title>", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Title fallback to first headline
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("First Head") } }),
  })
  local out = to_html.render(doc)
  check(
    "title falls back to first headline",
    out:find("<title>First Head</title>", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Headlines map to <hN>
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Top") } }),
    A.headline({ level = 2, title = { A.text("Sub") } }),
    A.headline({ level = 3, title = { A.text("Deep") } }),
  })
  local out = to_html.render(doc)
  check(
    "level 1 -> <h1>Top</h1>",
    out:find('<h1 id="top"><span class="section-number-1">1.</span> Top</h1>', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "level 2 -> <h2>Sub</h2>",
    out:find('<h2 id="sub"><span class="section-number-2">1.1.</span> Sub</h2>', 1, true) ~= nil
  )
  check(
    "level 3 -> <h3>Deep</h3>",
    out:find('<h3 id="deep"><span class="section-number-3">1.1.1.</span> Deep</h3>', 1, true) ~= nil
  )
end

-- Headline level clamps to 6
do
  local doc = A.document({
    A.headline({ level = 9, title = { A.text("Way deep") } }),
  })
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    headline_levels = 9,
  })
  local out = to_html.render(doc)
  check(
    "level 9 clamps to <h6>",
    out:find('<h6 id="way-deep">', 1, true) ~= nil and out:find("Way deep</h6>", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Paragraph wrapped in <p>...</p>
do
  local doc = A.document({
    A.paragraph({ A.text("Hello world.") }),
  })
  local out = to_html.render(doc)
  check("paragraph wrapped in <p>", out:find("<p>Hello world.</p>", 1, true) ~= nil, "got: " .. out)
end

-- Emphasis (6 styles)
do
  local doc = A.document({
    A.paragraph({
      A.text("a "),
      A.emphasis("bold", { A.text("B") }),
      A.text(" b "),
      A.emphasis("italic", { A.text("I") }),
      A.text(" c "),
      A.emphasis("underline", { A.text("U") }),
      A.text(" d "),
      A.emphasis("strike", { A.text("S") }),
      A.text(" e "),
      A.emphasis("verbatim", { A.text("V") }),
      A.text(" f "),
      A.emphasis("code", { A.text("C") }),
    }),
  })
  local out = to_html.render(doc)
  check("bold -> <strong>", out:find("<strong>B</strong>", 1, true) ~= nil, "got: " .. out)
  check("italic -> <em>", out:find("<em>I</em>", 1, true) ~= nil)
  check("underline -> <u>", out:find("<u>U</u>", 1, true) ~= nil)
  check("strike -> <del>", out:find("<del>S</del>", 1, true) ~= nil)
  check("verbatim -> <code>", out:find("<code>V</code>", 1, true) ~= nil)
  check("code -> <code>", out:find("<code>C</code>", 1, true) ~= nil)
end

-- Inline link
do
  local doc = A.document({
    A.paragraph({
      A.link("https://example.com", { A.text("a link") }),
      A.text(" and "),
      A.link("https://naked.example.com"),
    }),
  })
  local out = to_html.render(doc)
  check(
    "link with description",
    out:find('<a href="https://example.com">a link</a>', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "bare link uses target as text",
    out:find('<a href="https://naked.example.com">https://naked.example.com</a>', 1, true) ~= nil,
    "got: " .. out
  )
end

-- Inline image
do
  local doc = A.document({
    A.paragraph({
      A.text("see "),
      { kind = "image", target = "fig.png", alt = "fig" },
      A.text(" here"),
    }),
  })
  local out = to_html.render(doc)
  check(
    "inline image with description -> hyperlink",
    out:find('<a href="fig.png">fig</a>', 1, true) ~= nil,
    "got: " .. out
  )
end

-- Image without alt falls back to target as alt.
do
  local doc = A.document({
    A.paragraph({
      { kind = "image", target = "x.png" },
    }),
  })
  local out = to_html.render(doc)
  check(
    "image no alt falls back to target",
    out:find('<img src="x.png" alt="x.png">', 1, true) ~= nil,
    "got: " .. out
  )
end

-- Math: inline + display + MathJax loader
do
  local doc = A.document({
    A.paragraph({
      A.text("inline: "),
      { kind = "math", display = false, body = "x^2" },
      A.text(" display: "),
      { kind = "math", display = true, body = "\\int_0^1 x" },
    }),
  })
  local out = to_html.render(doc)
  check("inline math passes through verbatim", out:find("$x^2$", 1, true) ~= nil, "got: " .. out)
  check(
    "display math passes through verbatim",
    out:find("\\[\\int_0^1 x\\]", 1, true) ~= nil,
    "got: " .. out
  )
  check("head loads mathjax when math present", out:find("mathjax", 1, true) ~= nil)
end

-- Document without math -> no MathJax loader.
do
  local doc = A.document({
    A.paragraph({ A.text("plain text") }),
  })
  local out = to_html.render(doc)
  check("no math -> head omits mathjax", out:find("mathjax", 1, true) == nil, "got: " .. out)
end

-- HTML escaping
do
  local doc = A.document({
    A.paragraph({ A.text('<script>alert("x" & "y")</script>') }),
  })
  local out = to_html.render(doc)
  check("< escaped to &lt;", out:find("&lt;script&gt;", 1, true) ~= nil, "got: " .. out)
  check("> escaped to &gt;", out:find("&lt;/script&gt;", 1, true) ~= nil)
  check("& escaped to &amp;", out:find("&amp;", 1, true) ~= nil)
  check('" escaped to &quot;', out:find("&quot;", 1, true) ~= nil)
  check(
    "raw <script> never present in output",
    out:find("<script>alert", 1, true) == nil,
    "got: " .. out
  )
end

-- minimal_style = false drops <style>
do
  local doc = A.document({
    A.paragraph({ A.text("body") }),
  })
  local out = to_html.render(doc, { minimal_style = false })
  check("minimal_style=false omits <style>", out:find("<style>", 1, true) == nil, "got: " .. out)
end

-- Linebreak -> <br>
do
  local doc = A.document({
    A.paragraph({
      A.text("first"),
      A.linebreak(),
      A.text("second"),
    }),
  })
  local out = to_html.render(doc)
  check("linebreak emits <br>", out:find("first<br>second", 1, true) ~= nil, "got: " .. out)
end

-- List (unordered)
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ content = { A.paragraph({ A.text("one") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("two") }) } }),
    }),
  })
  local out = to_html.render(doc)
  check("unordered list wrapped in <ul>", out:find("<ul>", 1, true) ~= nil, "got: " .. out)
  check("closing </ul>", out:find("</ul>", 1, true) ~= nil)
  check("item 1 in <li>", out:find("<li>one</li>", 1, true) ~= nil, "got: " .. out)
  check("item 2 in <li>", out:find("<li>two</li>", 1, true) ~= nil)
end

-- List (ordered)
do
  local doc = A.document({
    A.list(true, {
      A.list_item({ content = { A.paragraph({ A.text("alpha") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("beta") }) } }),
    }),
  })
  local out = to_html.render(doc)
  check("ordered list wrapped in <ol>", out:find("<ol>", 1, true) ~= nil, "got: " .. out)
  check("closing </ol>", out:find("</ol>", 1, true) ~= nil)
end

-- List with checkboxes
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ checkbox = "todo", content = { A.paragraph({ A.text("a") }) } }),
      A.list_item({ checkbox = "done", content = { A.paragraph({ A.text("b") }) } }),
      A.list_item({ checkbox = "part", content = { A.paragraph({ A.text("c") }) } }),
    }),
  })
  local out = to_html.render(doc)
  check(
    "todo checkbox renders disabled input",
    out:find('<input type="checkbox" disabled', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "done checkbox renders checked disabled",
    out:find('<input type="checkbox" checked disabled', 1, true) ~= nil
  )
  check("a item content rendered", out:find("a</li>", 1, true) ~= nil)
  check("b item content rendered", out:find("b</li>", 1, true) ~= nil)
end

-- Nested list
do
  local doc = A.document({
    A.list(false, {
      A.list_item({
        content = {
          A.paragraph({ A.text("outer") }),
          A.list(false, {
            A.list_item({ content = { A.paragraph({ A.text("inner") }) } }),
          }),
        },
      }),
    }),
  })
  local out = to_html.render(doc)
  check(
    "outer list contains nested <ul>",
    out:find("outer", 1, true) ~= nil and out:find("<ul>.-<ul>") ~= nil,
    "got: " .. out
  )
  check("inner item still rendered", out:find("inner", 1, true) ~= nil)
end

-- code_block (with language)
do
  local doc = A.document({
    A.code_block("python", 'print("hi")'),
  })
  local out = to_html.render(doc)
  check(
    "code with language uses language- class",
    out:find('<pre><code class="language-python">', 1, true) ~= nil,
    "got: " .. out
  )
  check("code body html-escaped", out:find("print(&quot;hi&quot;)", 1, true) ~= nil)
  check("closing tags", out:find("</code></pre>", 1, true) ~= nil)
end

-- code_block (no language)
do
  local doc = A.document({
    A.code_block(nil, "raw"),
  })
  local out = to_html.render(doc)
  check(
    "code no language has no language- class",
    out:find("language-", 1, true) == nil,
    "got: " .. out
  )
  check(
    "code no language still uses <pre><code>",
    out:find("<pre><code>raw</code></pre>", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Block: example
do
  local doc = A.document({
    A.block("example", { body = "raw <text>" }),
  })
  local out = to_html.render(doc)
  check(
    "example uses <pre class=example>",
    out:find('<pre class="example">', 1, true) ~= nil and out:find("</pre>", 1, true) ~= nil,
    "got: " .. out
  )
  check("example body escaped", out:find("raw &lt;text&gt;", 1, true) ~= nil)
end

-- Block: verse
do
  local doc = A.document({
    A.block("verse", { body = "verse 1\nverse 2" }),
  })
  local out = to_html.render(doc)
  check(
    "verse uses <p class=verse> with <br />",
    out:find('<p class="verse">\nverse 1<br />\nverse 2<br />\n</p>', 1, true) ~= nil,
    "got: " .. out
  )
end

-- Block: quote
do
  local doc = A.document({
    A.block("quote", {
      content = {
        A.paragraph({ A.text("first") }),
        A.paragraph({ A.text("second") }),
      },
    }),
  })
  local out = to_html.render(doc)
  check(
    "quote uses <blockquote>",
    out:find("<blockquote>", 1, true) ~= nil and out:find("</blockquote>", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "quote paragraphs as <p>",
    out:find("<p>first</p>", 1, true) ~= nil and out:find("<p>second</p>", 1, true) ~= nil
  )
end

-- Block: export (dropped)
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    A.block("export", { body = "<html>raw</html>" }),
    A.paragraph({ A.text("after") }),
  })
  local out = to_html.render(doc)
  check("export body dropped", out:find("<html>raw</html>", 1, true) == nil, "got: " .. out)
  check(
    "export drop preserves surrounding paragraphs",
    out:find("<p>before</p>", 1, true) ~= nil and out:find("<p>after</p>", 1, true) ~= nil
  )
end

-- Table with header divider
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l", "l" },
      rows = {
        { cells = { { A.text("name") }, { A.text("age") } }, sep = false },
        { sep = true, cells = {} },
        { cells = { { A.text("ada") }, { A.text("36") } }, sep = false },
        { cells = { { A.text("ben") }, { A.text("41") } }, sep = false },
      },
    },
  })
  local out = to_html.render(doc)
  check("<table> wrapper", out:find("<table>", 1, true) ~= nil, "got: " .. out)
  check("<thead> present", out:find("<thead>", 1, true) ~= nil)
  check("<th>name</th>", out:find('<th class="org-left">name</th>', 1, true) ~= nil)
  check("<th>age</th>", out:find('<th class="org-right">age</th>', 1, true) ~= nil)
  check("<tbody> present", out:find("<tbody>", 1, true) ~= nil)
  check("<td>ada</td>", out:find('<td class="org-left">ada</td>', 1, true) ~= nil)
  check("<td>36</td>", out:find('<td class="org-right">36</td>', 1, true) ~= nil)
end

-- Table with no header divider
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("a") } }, sep = false },
        { cells = { { A.text("b") } }, sep = false },
      },
    },
  })
  local out = to_html.render(doc)
  check("no sep -> no <thead>", out:find("<thead>", 1, true) == nil, "got: " .. out)
  check("data still in <tbody>", out:find("<tbody>", 1, true) ~= nil)
  check("data row 1 as <td>", out:find('<td class="org-left">a</td>', 1, true) ~= nil)
end

-- Table with mid-table sep (extra sep dropped)
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("h") } }, sep = false },
        { sep = true, cells = {} },
        { cells = { { A.text("a1") } }, sep = false },
        { sep = true, cells = {} }, -- mid-table sep: drop
        { cells = { { A.text("a2") } }, sep = false },
      },
    },
  })
  local out = to_html.render(doc)
  check(
    "header in <thead>",
    out:find('<th class="org-left">h</th>', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "a1 + a2 both in tbody",
    out:find('<td class="org-left">a1</td>', 1, true) ~= nil
      and out:find('<td class="org-left">a2</td>', 1, true) ~= nil
  )
end

-- Table cell content escaped
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("<x>") } }, sep = false },
      },
    },
  })
  local out = to_html.render(doc)
  check(
    "cell content escaped",
    out:find('<td class="org-left">&lt;x&gt;</td>', 1, true) ~= nil,
    "got: " .. out
  )
end

-- Block-level image
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    { kind = "image", target = "fig.png", alt = "diagram" },
    A.paragraph({ A.text("after") }),
  })
  local out = to_html.render(doc)
  check(
    "block image with description renders as a hyperlink",
    out:find('<p><a href="fig.png">diagram</a></p>', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "paragraphs around block image still present",
    out:find("<p>before</p>", 1, true) ~= nil and out:find("<p>after</p>", 1, true) ~= nil
  )
end

-- Block-level image with no alt (fallback to target)
do
  local doc = A.document({ { kind = "image", target = "x.png" } })
  local out = to_html.render(doc)
  check(
    "image with no alt falls back to target",
    out:find('<img src="x.png" alt="x.png">', 1, true) ~= nil,
    "got: " .. out
  )
end

-- Horizontal rule
do
  local doc = A.document({
    A.paragraph({ A.text("above") }),
    A.rule(),
    A.paragraph({ A.text("below") }),
  })
  local out = to_html.render(doc)
  check("rule renders as <hr>", out:find("<hr>", 1, true) ~= nil, "got: " .. out)
end

-- footnote_definition
do
  local doc = A.document({
    A.paragraph({
      A.text("claim"),
      { kind = "footnote_ref", label = "1" },
    }),
    A.footnote_definition("1", { A.paragraph({ A.text("the footnote body") }) }),
  })
  local out = to_html.render(doc)
  check(
    "inline footnote_ref renders sup link",
    out:find('<sup><a href="#fn-1">[1]</a></sup>', 1, true) ~= nil,
    "got: " .. out
  )
  check("footnote_definition has matching id anchor", out:find('id="fn-1"', 1, true) ~= nil)
  check("footnote definition has label sup", out:find("<sup>[1]</sup>", 1, true) ~= nil)
  check("footnote body present", out:find("the footnote body", 1, true) ~= nil)
end

-- Multi-paragraph footnote
do
  local doc = A.document({
    A.paragraph({ A.text("x"), A.footnote_ref("note") }),
    A.footnote_definition("note", {
      A.paragraph({ A.text("first") }),
      A.paragraph({ A.text("second") }),
    }),
  })
  local out = to_html.render(doc)
  check(
    "multi-paragraph footnote: first paragraph after label",
    out:find('id="fn-note"><sup>[1]</sup> first', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "multi-paragraph footnote: second paragraph wrapped in <p>",
    out:find("<p>second</p>", 1, true) ~= nil
  )
end

-- Directive dropped
do
  local doc = A.document({
    A.directive("TITLE", "ignored title"),
    A.directive("AUTHOR", "Jane"),
    A.paragraph({ A.text("body") }),
  })
  local out = to_html.render(doc)
  check("directive AUTHOR not rendered in body", out:find("Jane", 1, true) == nil, "got: " .. out)
  check("paragraph still rendered", out:find("<p>body</p>", 1, true) ~= nil)
end

-- <title> from a headline is plain text escaped once
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = {
        A.text("Tom & "),
        A.emphasis("bold", { A.text("Jerry") }),
        A.text(" <3"),
      },
    }),
  })
  local out = to_html.render(doc)
  check(
    "headline title escaped once, markup stripped",
    out:find("<title>Tom &amp; Jerry &lt;3</title>", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Inline kinds: subscript, superscript, entity, cookie, timestamp, target, macro
do
  local doc = A.document({
    A.paragraph({
      A.text("H"),
      A.subscript({ A.text("2") }),
      A.text("O "),
      A.entity("copy"),
      A.text(" "),
      A.entity("alpha"),
      A.text(" "),
      A.statistics_cookie("[2/3]"),
      A.text(" "),
      A.statistics_cookie("[50%]"),
      A.text(" "),
      A.timestamp("<2026-09-10 Thu>", "active"),
      A.text(" "),
      A.target("anchor"),
      A.text(" "),
      A.macro("title", {}),
      A.text(" x"),
      A.superscript({ A.text("2") }),
      A.text(" "),
      A.entity("nosuchentity"),
    }),
  })
  local out = to_html.render(doc)
  check("html subscript -> <sub>", out:find("H<sub>2</sub>O", 1, true) ~= nil, "got: " .. out)
  check("html superscript -> <sup>", out:find("x<sup>2</sup>", 1, true) ~= nil)
  check("html entity -> html entity", out:find("&copy; &alpha;", 1, true) ~= nil)
  check("html cookie -> <code>", out:find("<code>[2/3]</code> <code>[50%]</code>", 1, true) ~= nil)
  check(
    "html timestamp -> timestamp spans",
    out:find(
      '<span class="timestamp-wrapper"><span class="timestamp">&lt;2026-09-10 Thu&gt;</span></span>',
      1,
      true
    ) ~= nil
  )
  check("html target -> anchor", out:find('<a id="anchor"></a>', 1, true) ~= nil)
  check("html macro kept as text", out:find("{{{title}}}", 1, true) ~= nil)
  check("html unknown entity kept as text", out:find("\\nosuchentity", 1, true) ~= nil)
end

-- Every block kind inside a list item renders
do
  local doc = A.document({
    A.list(false, {
      A.list_item({
        content = {
          A.paragraph({ A.text("intro") }),
          A.code_block("lua", "print(1)"),
          A.block("quote", { content = { A.paragraph({ A.text("quoted") }) } }),
        },
      }),
    }),
  })
  local out = to_html.render(doc)
  check(
    "code block inside <li>",
    out:find('<li>intro\n<pre><code class="language-lua">print(1)</code></pre>', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "quote inside <li>",
    out:find("<blockquote>\n<p>quoted</p>\n</blockquote></li>", 1, true) ~= nil
  )
end

-- Footnotes: numbered by first reference, inline bodies rendered,
-- definitions collected at the end.
do
  local doc = A.document({
    A.paragraph({
      A.text("claim"),
      A.footnote_ref("note"),
      A.text(" and"),
      A.footnote_ref(nil, { A.text("inline body") }),
      A.text("."),
    }),
    A.footnote_definition("note", { A.paragraph({ A.text("The definition.") }) }),
    A.paragraph({ A.text("after") }),
  })
  local out = to_html.render(doc)
  check(
    "labelled ref numbered 1",
    out:find('claim<sup><a href="#fn-note">[1]</a></sup>', 1, true) ~= nil,
    "got: " .. out
  )
  check("inline ref numbered 2", out:find('and<sup><a href="#fn-2">[2]</a></sup>', 1, true) ~= nil)
  check(
    "definitions after the body",
    out:find(
      '<p>after</p>\n<div class="footdef" id="fn-note"><sup>[1]</sup> The definition.</div>\n'
        .. '<div class="footdef" id="fn-2"><sup>[2]</sup> inline body</div>',
      1,
      true
    ) ~= nil
  )
end

-- Internal and file links resolve to ids / .html paths
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Target heading") } }),
    A.headline({ level = 1, title = { A.text("Custom") }, properties = { CUSTOM_ID = "custom" } }),
    A.headline({ level = 1, title = { A.text("By uuid") }, properties = { ID = "abc-123" } }),
    A.paragraph({ A.text("see "), A.target("anchor"), A.text(" here") }),
    A.paragraph({
      A.link("file:notes.org", { A.text("Notes") }),
      A.text(" "),
      A.link("*Target heading", { A.text("internal") }),
      A.text(" "),
      A.link("#custom", { A.text("by id") }),
      A.text(" "),
      A.link("id:abc-123", { A.text("by uuid") }),
      A.text(" "),
      A.link("anchor", { A.text("to target") }),
      A.text(" "),
      A.link("*Target heading"),
      A.text(" "),
      A.link("*Missing", { A.text("gone") }),
      A.text(" "),
      A.link("https://x.y/a?b=1&c=2", { A.text("q") }),
    }),
  })
  local out = to_html.render(doc)
  check(
    "headline id from title",
    out:find(
      '<h1 id="target-heading"><span class="section-number-1">1.</span> Target heading</h1>',
      1,
      true
    ) ~= nil,
    "got: " .. out
  )
  check(
    "headline id from CUSTOM_ID",
    out:find('<h1 id="custom"><span class="section-number-1">2.</span> Custom</h1>', 1, true) ~= nil
  )
  check("file:x.org -> x.html", out:find('<a href="notes.html">Notes</a>', 1, true) ~= nil)
  check("*Title -> #id", out:find('<a href="#target-heading">internal</a>', 1, true) ~= nil)
  check("#custom -> #custom", out:find('<a href="#custom">by id</a>', 1, true) ~= nil)
  check("id: -> headline id", out:find('<a href="#by-uuid">by uuid</a>', 1, true) ~= nil)
  check("target -> #name", out:find('<a href="#anchor">to target</a>', 1, true) ~= nil)
  check(
    "no description -> headline title",
    out:find('<a href="#target-heading">Target heading</a>', 1, true) ~= nil
  )
  check("unresolved fuzzy -> <i>desc</i>", out:find("<i>gone</i>", 1, true) ~= nil)
  check("external untouched", out:find('<a href="https://x.y/a?b=1&amp;c=2">q</a>', 1, true) ~= nil)
end

-- Fixed-width lines (`: text`) -- every short babel result is one.
do
  local doc = A.document({
    { kind = "fixed_width", body = "42\nnext", affiliated = { { name = "RESULTS", value = "" } } },
  })
  local out = to_html.render(doc)
  check(
    "fixed_width -> <pre class=example>",
    out:find('<pre class="example">\n42\nnext\n</pre>', 1, true) ~= nil,
    "got: " .. out
  )
end

-- LaTeX environments pass through raw, or as literal text under tex:verbatim.
do
  local body = "\\begin{equation}\nx = 1\n\\end{equation}"
  local doc = A.document({ { kind = "latex_environment", name = "equation", body = body } })
  local out = to_html.render(doc)
  check("latex_environment passes through raw", out:find(body, 1, true) ~= nil, "got: " .. out)

  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_latex = "verbatim",
  })
  local verbatim = to_html.render(doc)
  check(
    "tex:verbatim renders the environment as literal text",
    verbatim:find("<p>" .. body .. "</p>", 1, true) ~= nil,
    "got: " .. verbatim
  )
end

-- Greater blocks: center, custom, and backend-gated export blocks.
do
  local doc = A.document({
    A.block("center", { content = { A.paragraph({ A.text("mid") }) } }),
    A.block("myblock", { content = { A.paragraph({ A.text("custom") }) } }),
    A.block("export", { backend = "html", body = "<b>raw</b>" }),
    A.block("export", { backend = "latex", body = "\\raw{}" }),
  })
  local out = to_html.render(doc)
  check(
    "center block -> div.org-center",
    out:find('<div class="org-center">\n<p>mid</p>\n</div>', 1, true) ~= nil,
    "got: " .. out
  )
  check("custom block -> div named after it", out:find('<div class="myblock">', 1, true) ~= nil)
  check("export html passes through", out:find("<b>raw</b>", 1, true) ~= nil)
  check("export latex is dropped", out:find("raw{}", 1, true) == nil)
end

-- TODO keyword, priority cookie and tags reach the heading.
do
  local doc = A.document({
    A.headline({
      level = 1,
      todo = "TODO",
      todo_type = "todo",
      priority = "A",
      tags = { "work", "urgent" },
      title = { A.text("Task one") },
    }),
    A.headline({ level = 1, todo = "DONE", todo_type = "done", title = { A.text("Done one") } }),
  })
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_priority = true,
    with_toc = false,
  })
  local out = to_html.render(doc)
  check(
    "TODO keyword marked up",
    out:find('<span class="todo TODO">TODO</span>', 1, true) ~= nil,
    "got: " .. out
  )
  check("DONE keyword marked up", out:find('<span class="done DONE">DONE</span>', 1, true) ~= nil)
  check("priority cookie marked up", out:find('<span class="priority">[A]</span>', 1, true) ~= nil)
  check(
    "tags marked up",
    out:find(
      '&#xa0;&#xa0;&#xa0;<span class="tag"><span class="work">work</span>&#xa0;<span class="urgent">urgent</span></span>',
      1,
      true
    ) ~= nil
  )

  doc.options.with_todo_keywords = false
  doc.options.with_priority = false
  doc.options.with_tags = false
  local bare = to_html.render(doc)
  check(
    "options switch each part off",
    bare:find("todo TODO", 1, true) == nil
      and bare:find('class="priority"', 1, true) == nil
      and bare:find('class="tag"', 1, true) == nil,
    "got: " .. bare
  )
end

-- Description lists keep their terms.
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ tag = { A.text("term") }, content = { A.paragraph({ A.text("definition") }) } }),
    }),
  })
  local out = to_html.render(doc)
  check(
    "description list -> dl/dt/dd",
    out:find('<dl class="org-dl">\n<dt>term</dt><dd>definition</dd>\n</dl>', 1, true) ~= nil,
    "got: " .. out
  )
end

-- Verse keeps inline markup; newlines become <br>, indent &#xa0;.
do
  local doc = A.document({
    A.block("verse", {
      content = {
        A.paragraph({
          A.text("line one "),
          A.emphasis("bold", { A.text("b") }),
          A.text("\n   indented line"),
        }),
      },
    }),
  })
  local out = to_html.render(doc)
  check(
    "verse keeps markup and indentation",
    out:find(
      '<p class="verse">\nline one <strong>b</strong><br />\n&#xa0;&#xa0;&#xa0;indented line<br />\n</p>',
      1,
      true
    ) ~= nil,
    "got: " .. out
  )
end

-- Affiliated keywords: CAPTION / NAME / ATTR_HTML.
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      affiliated = {
        {
          name = "CAPTION",
          value = "A caption with *bold*",
          inline = {
            A.text("A caption with "),
            A.emphasis("bold", { A.text("bold") }),
          },
        },
        { name = "NAME", value = "tbl-one" },
        { name = "ATTR_HTML", value = ":width 100 :class fancy" },
      },
      rows = { { cells = { { A.text("a") } }, sep = false } },
    },
    A.code_block("lua", "print(1)"),
    { kind = "image", target = "./img.png" },
  })
  doc.children[2].affiliated = { { name = "CAPTION", value = "Code caption" } }
  doc.children[3].affiliated = {
    { name = "CAPTION", value = "Pic caption" },
    { name = "NAME", value = "fig-one" },
    { name = "ATTR_HTML", value = ":width 100" },
  }
  local out = to_html.render(doc)
  check(
    "table caption keeps its markup",
    out:find(
      '<caption class="t-above"><span class="table-number">Table 1:</span> A caption with <strong>bold</strong></caption>',
      1,
      true
    ) ~= nil,
    "got: " .. out
  )
  check("NAME becomes an id", out:find('<table id="tbl-one"', 1, true) ~= nil)
  check("ATTR_HTML becomes attributes", out:find('width="100" class="fancy"', 1, true) ~= nil)
  check(
    "src block caption",
    out:find(
      '<label class="org-src-name"><span class="listing-number">Listing 1: </span>Code caption</label>',
      1,
      true
    ) ~= nil
  )
  check(
    "image caption",
    out:find('<span class="figure-number">Figure 1: </span>Pic caption', 1, true) ~= nil
  )
end

-- Table of contents, numbered like the headings it points at.
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = { A.text("One") },
      children = { A.headline({ level = 2, title = { A.text("Deep") } }) },
    }),
    A.headline({ level = 1, title = { A.text("Two") } }),
  })
  local out = to_html.render(doc)
  check(
    "toc container",
    out:find('<div id="table-of-contents" role="doc-toc">', 1, true) ~= nil,
    "got: " .. out
  )
  check("toc entry numbered", out:find('<li><a href="#one">1. One</a>', 1, true) ~= nil)
  check("toc nests", out:find('<li><a href="#deep">1.1. Deep</a>', 1, true) ~= nil)
  check("toc second top entry", out:find('<li><a href="#two">2. Two</a>', 1, true) ~= nil)

  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_toc = false,
  })
  check("toc:nil suppresses it", to_html.render(doc):find("table-of-contents", 1, true) == nil)

  doc.options.with_toc = 1
  local shallow = to_html.render(doc)
  check(
    "toc depth limits the entries",
    shallow:find('href="#one"', 1, true) ~= nil and shallow:find('href="#deep"', 1, true) == nil,
    "got: " .. shallow
  )
end

-- Alignment cookies are metadata, not a data row.
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "r", "l", "c" },
      rows = {
        { cells = { { A.text("<r>") }, { A.text("<l>") }, { A.text("<c>") } }, sep = false },
        { cells = { { A.text("1") }, { A.text("a") }, { A.text("x") } }, sep = false },
      },
    },
  })
  local out = to_html.render(doc)
  check("cookie row is not rendered", out:find("&lt;r&gt;", 1, true) == nil, "got: " .. out)
  check(
    "cookies become a colgroup",
    out:find(
      '<colgroup><col class="org-right" /><col class="org-left" /><col class="org-center" /></colgroup>',
      1,
      true
    ) ~= nil
  )
end

-- Partial checkboxes stay distinguishable from unchecked ones.
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ checkbox = "todo", content = { A.paragraph({ A.text("t") }) } }),
      A.list_item({ checkbox = "part", content = { A.paragraph({ A.text("p") }) } }),
      A.list_item({ checkbox = "done", content = { A.paragraph({ A.text("d") }) } }),
    }),
  })
  local out = to_html.render(doc)
  check(
    "tri-state checkbox classes",
    out:find('<li class="off">', 1, true) ~= nil
      and out:find('<li class="trans">', 1, true) ~= nil
      and out:find('<li class="on">', 1, true) ~= nil,
    "got: " .. out
  )
end

-- Entities keep working with the `{}` terminator; head reads the options.
do
  local doc = A.document({ A.paragraph({ A.entity("alpha{}"), A.text("text") }) })
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    author = "Jane Doe",
    date = "2026-01-02",
    language = "ja",
    time_stamp_file = false,
  })
  local out = to_html.render(doc)
  check("\\alpha{} is the alpha entity", out:find("&alpha;text", 1, true) ~= nil, "got: " .. out)
  check("language reaches <html>", out:find('<html lang="ja">', 1, true) ~= nil)
  check(
    "author reaches <head>",
    out:find('<meta name="author" content="Jane Doe">', 1, true) ~= nil
  )
  check(
    "date reaches <head>",
    out:find('<meta name="dcterms.date" content="2026-01-02">', 1, true) ~= nil
  )
end

-- Special strings, smart quotes and preserved line breaks.
do
  local doc = A.document({
    A.paragraph({ A.text('He said "hello" -- it\'s a test... and---dash\nline two') }),
  })
  local plain = to_html.render(doc)
  check(
    "special strings on by default",
    plain:find("&#x2013;", 1, true) ~= nil
      and plain:find("&#x2014;", 1, true) ~= nil
      and plain:find("&#x2026;", 1, true) ~= nil,
    "got: " .. plain
  )
  check("smart quotes off by default", plain:find("&ldquo;", 1, true) == nil)
  check("line breaks not preserved by default", plain:find("<br />", 1, true) == nil)

  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_smart_quotes = true,
    preserve_breaks = true,
  })
  local rich = to_html.render(doc)
  check(
    "smart quotes",
    rich:find("&ldquo;hello&rdquo;", 1, true) ~= nil and rich:find("it&rsquo;s", 1, true) ~= nil,
    "got: " .. rich
  )
  check("preserved break", rich:find("dash<br />\nline two", 1, true) ~= nil, "got: " .. rich)

  doc.options.with_special_strings = false
  check("-:nil leaves the text alone", to_html.render(doc):find("a test...", 1, true) ~= nil)
end

-- Diary sexp timestamps.  `<%%(...)>` on a line of its own is a paragraph
-- holding a diary timestamp, exactly as it is mid-paragraph; a bare
-- `%%(...)` is a diary-sexp element, which no backend transcodes.
do
  local from_org = require("organ.ast.from_org")
  local span = '<span class="timestamp-wrapper"><span class="timestamp">'
    .. "&lt;%%(diary-float t 4 2)&gt;</span></span>"

  local standalone = to_html.render(from_org.from_lines({ "<%%(diary-float t 4 2)>" }))
  check(
    "standalone diary sexp is a paragraph with a timestamp",
    standalone:find("<p>" .. span .. "</p>", 1, true) ~= nil,
    "got: " .. standalone
  )

  local inline = to_html.render(from_org.from_lines({ "Inline <%%(diary-float t 4 2)> here." }))
  check(
    "inline diary sexp keeps its timestamp",
    inline:find("<p>Inline " .. span .. " here.</p>", 1, true) ~= nil,
    "got: " .. inline
  )

  local bare = to_html.render(from_org.from_lines({ "%%(diary-float t 4 2)" }))
  check(
    "bare diary-sexp element emits nothing",
    bare:find("diary-float", 1, true) == nil,
    "got: " .. bare
  )
end

-- `#+OPTIONS: H:N` (org-export-low-level-p): a headline deeper than N is
-- a list item, not a heading; `num:` picks the list type.
do
  local function tree()
    return A.document({
      A.headline({
        level = 1,
        title = { A.text("Top") },
        children = {
          A.headline({
            level = 2,
            title = { A.text("Sub") },
            children = {
              A.headline({
                level = 3,
                title = { A.text("Deep") },
                children = {
                  A.paragraph({ A.text("body") }),
                  A.headline({ level = 4, title = { A.text("Deeper") } }),
                },
              }),
              A.headline({ level = 3, title = { A.text("Deep B") } }),
            },
          }),
        },
      }),
    })
  end
  local function opts(over)
    return vim.tbl_extend(
      "force",
      require("organ.export.options").defaults(),
      { headline_levels = 2, with_toc = false, with_section_numbers = false },
      over or {}
    )
  end

  local doc = tree()
  doc.options = opts()
  local out = to_html.render(doc)
  check("H:2 keeps level 2 a heading", out:find('<h2 id="sub">', 1, true) ~= nil, "got: " .. out)
  check("H:2 emits no <h3>", out:find("<h3", 1, true) == nil, "got: " .. out)
  check(
    "H:2 demotes level 3 to a list item",
    out:find('<ul>\n<li><a id="deep"></a>Deep<br />\n<p>body</p>', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "H:2 nests the level 4 list inside its parent item",
    out:find('<ul>\n<li><a id="deeper"></a>Deeper<br /></li>\n</ul></li>', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "sibling demoted headlines share one list",
    select(2, out:gsub("<ul>", "")) == 2 and out:find('<li><a id="deep-b">', 1, true) ~= nil,
    "got: " .. out
  )

  local numbered = tree()
  numbered.options = opts({ with_section_numbers = true })
  local nout = to_html.render(numbered)
  check("num:t demotes into <ol>", nout:find("<ol>", 1, true) ~= nil, "got: " .. nout)

  local capped = tree()
  capped.options = opts({ with_section_numbers = 2 })
  check(
    "num:2 leaves the demoted list unordered",
    to_html.render(capped):find("<ol>", 1, true) == nil
  )
end

-- `#+TOC:` as a directive (org-html-keyword / org-latex-keyword /
-- org-md-keyword / org-ascii-keyword / org-texinfo-keyword), verified
-- against Emacs 30.2 / Org 9.7.11.
do
  local from_org = require("organ.ast.from_org")
  local src = {
    "#+OPTIONS: toc:nil num:nil",
    "",
    "#+TOC: headlines 2",
    "",
    "* One",
    "#+CAPTION: Table one",
    "| a | b |",
    "",
    "#+CAPTION: Listing one",
    "#+BEGIN_SRC lua",
    "print(1)",
    "#+END_SRC",
    "",
    "** Two",
    "*** Three",
    "",
    "#+TOC: tables",
    "",
    "#+TOC: listings",
    "",
    "#+TOC: figures",
    "",
    "* Four",
    "#+TOC: headlines 1 local",
    "** Five",
  }

  local out = to_html.render(from_org.from_lines(src))
  check(
    "#+TOC: headlines builds the document TOC under toc:nil",
    out:find('<div id="table-of-contents" role="doc-toc">', 1, true) ~= nil
      and out:find('<a href="#one">One</a>', 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "#+TOC: headlines 2 stops at level 2",
    out:find('href="#three"', 1, true) == nil,
    "got: " .. out
  )
  check(
    "#+TOC: tables lists the captioned table",
    out:find('<div id="list-of-tables">', 1, true) ~= nil
      and out:find('<li><span class="table-number">Table 1:</span> Table one</li>', 1, true)
        ~= nil,
    "got: " .. out
  )
  check(
    "#+TOC: listings lists the captioned src block",
    out:find('<div id="list-of-listings">', 1, true) ~= nil
      and out:find('<li><span class="listing-number">Listing 1:</span> Listing one</li>', 1, true)
        ~= nil,
    "got: " .. out
  )
  check(
    "#+TOC: figures renders nothing, as in ox-html",
    out:find("list-of-figures", 1, true) == nil
  )
  check(
    "#+TOC: ... local is the bare list of the enclosing subtree",
    out:find(
      '<div id="text-table-of-contents-1" role="doc-toc">\n<ul>\n<li><a href="#five">Five</a>',
      1,
      true
    ) ~= nil,
    "got: " .. out
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_html_test: PASS")
os.exit(0)
