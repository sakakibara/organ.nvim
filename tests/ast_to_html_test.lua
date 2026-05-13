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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_html_test: PASS")
os.exit(0)
