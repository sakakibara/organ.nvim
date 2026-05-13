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

-- ---- empty document --------------------------------------------------
do
  local out = to_html.render(A.document({}))
  check("DOCTYPE present", out:find("<!DOCTYPE html>", 1, true) ~= nil, "got: " .. out)
  check("html lang=en present", out:find('<html lang="en">', 1, true) ~= nil)
  check("default title is Untitled", out:find("<title>Untitled</title>", 1, true) ~= nil)
  check("body present", out:find("<body>", 1, true) ~= nil)
end

-- ---- title from TITLE directive --------------------------------------
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

-- ---- title fallback to first headline --------------------------------
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

-- ---- headlines map to <hN> -------------------------------------------
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Top") } }),
    A.headline({ level = 2, title = { A.text("Sub") } }),
    A.headline({ level = 3, title = { A.text("Deep") } }),
  })
  local out = to_html.render(doc)
  check("level 1 -> <h1>Top</h1>", out:find("<h1>Top</h1>", 1, true) ~= nil, "got: " .. out)
  check("level 2 -> <h2>Sub</h2>", out:find("<h2>Sub</h2>", 1, true) ~= nil)
  check("level 3 -> <h3>Deep</h3>", out:find("<h3>Deep</h3>", 1, true) ~= nil)
end

-- ---- headline level clamps to 6 --------------------------------------
do
  local doc = A.document({
    A.headline({ level = 9, title = { A.text("Way deep") } }),
  })
  local out = to_html.render(doc)
  check("level 9 clamps to <h6>", out:find("<h6>Way deep</h6>", 1, true) ~= nil, "got: " .. out)
end

-- ---- paragraph wrapped in <p>...</p> ---------------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("Hello world.") }),
  })
  local out = to_html.render(doc)
  check("paragraph wrapped in <p>", out:find("<p>Hello world.</p>", 1, true) ~= nil, "got: " .. out)
end

-- ---- emphasis (6 styles) ---------------------------------------------
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

-- ---- inline link -----------------------------------------------------
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

-- ---- inline image ---------------------------------------------------
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
    "inline image with alt -> <img src alt>",
    out:find('<img src="fig.png" alt="fig">', 1, true) ~= nil,
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

-- ---- math: inline + display + MathJax loader -------------------------
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

-- ---- HTML escaping --------------------------------------------------
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

-- ---- minimal_style = false drops <style> ----------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("body") }),
  })
  local out = to_html.render(doc, { minimal_style = false })
  check("minimal_style=false omits <style>", out:find("<style>", 1, true) == nil, "got: " .. out)
end

-- ---- linebreak -> <br> ----------------------------------------------
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

-- ---- list (unordered) ------------------------------------------------
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

-- ---- list (ordered) --------------------------------------------------
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

-- ---- list with checkboxes -------------------------------------------
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

-- ---- nested list ----------------------------------------------------
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

-- ---- code_block (with language) -------------------------------------
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

-- ---- code_block (no language) ---------------------------------------
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

-- ---- block: example -------------------------------------------------
do
  local doc = A.document({
    A.block("example", { body = "raw <text>" }),
  })
  local out = to_html.render(doc)
  check(
    "example uses <pre>",
    out:find("<pre>", 1, true) ~= nil and out:find("</pre>", 1, true) ~= nil,
    "got: " .. out
  )
  check("example body escaped", out:find("raw &lt;text&gt;", 1, true) ~= nil)
end

-- ---- block: verse ---------------------------------------------------
do
  local doc = A.document({
    A.block("verse", { body = "verse 1\nverse 2" }),
  })
  local out = to_html.render(doc)
  check("verse uses <pre>", out:find("<pre>verse 1\nverse 2</pre>", 1, true) ~= nil, "got: " .. out)
end

-- ---- block: quote ---------------------------------------------------
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

-- ---- block: export (dropped) ----------------------------------------
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

-- ---- table with header divider --------------------------------------
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
  check("<th>name</th>", out:find("<th>name</th>", 1, true) ~= nil)
  check("<th>age</th>", out:find("<th>age</th>", 1, true) ~= nil)
  check("<tbody> present", out:find("<tbody>", 1, true) ~= nil)
  check("<td>ada</td>", out:find("<td>ada</td>", 1, true) ~= nil)
  check("<td>36</td>", out:find("<td>36</td>", 1, true) ~= nil)
end

-- ---- table with no header divider ----------------------------------
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
  check("data row 1 as <td>", out:find("<td>a</td>", 1, true) ~= nil)
end

-- ---- table with mid-table sep (extra sep dropped) -------------------
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
  check("header in <thead>", out:find("<th>h</th>", 1, true) ~= nil, "got: " .. out)
  check(
    "a1 + a2 both in tbody",
    out:find("<td>a1</td>", 1, true) ~= nil and out:find("<td>a2</td>", 1, true) ~= nil
  )
end

-- ---- table cell content escaped -------------------------------------
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
  check("cell content escaped", out:find("<td>&lt;x&gt;</td>", 1, true) ~= nil, "got: " .. out)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_html_test: PASS")
os.exit(0)
