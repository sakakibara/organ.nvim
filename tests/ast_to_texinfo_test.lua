-- Unit tests for organ.ast.to_texinfo.  Build AST nodes via organ.ast
-- builders, render to Texinfo string, assert via substring matches.
--
-- Run via: nvim --headless -l tests/ast_to_texinfo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local A = require("organ.ast")
local to_texinfo = require("organ.ast.to_texinfo")

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
  local out = to_texinfo.render(A.document({}))
  check(
    "preamble contains \\input texinfo",
    out:find("\\input texinfo", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "default settitle is Untitled",
    out:find("@settitle Untitled", 1, true) ~= nil,
    "got: " .. out
  )
  check("default title page Untitled", out:find("@title Untitled", 1, true) ~= nil)
  check("@bye terminates document", out:find("@bye", 1, true) ~= nil)
end

-- ---- title from TITLE directive --------------------------------------
do
  local doc = A.document({
    A.directive("TITLE", "My Doc"),
    A.paragraph({ A.text("body") }),
  })
  local out = to_texinfo.render(doc)
  check("@settitle from TITLE", out:find("@settitle My Doc", 1, true) ~= nil, "got: " .. out)
  check("@title from TITLE", out:find("@title My Doc", 1, true) ~= nil)
end

-- ---- author from AUTHOR directive ------------------------------------
do
  local doc = A.document({
    A.directive("TITLE", "Doc"),
    A.directive("AUTHOR", "Sho"),
  })
  local out = to_texinfo.render(doc)
  check("@author from AUTHOR", out:find("@author Sho", 1, true) ~= nil, "got: " .. out)
end

-- ---- AUTHOR absent: no @author line ----------------------------------
do
  local doc = A.document({
    A.directive("TITLE", "Doc"),
  })
  local out = to_texinfo.render(doc)
  check("no @author when AUTHOR absent", out:find("@author", 1, true) == nil, "got: " .. out)
end

-- ---- filename default: title with spaces -> _ ------------------------
do
  local doc = A.document({
    A.directive("TITLE", "My Doc"),
  })
  local out = to_texinfo.render(doc)
  check(
    "default filename derived from title",
    out:find("@setfilename My_Doc.info", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- filename: FILENAME directive overrides --------------------------
do
  local doc = A.document({
    A.directive("TITLE", "Doc"),
    A.directive("FILENAME", "custom.info"),
  })
  local out = to_texinfo.render(doc)
  check(
    "FILENAME directive overrides default",
    out:find("@setfilename custom.info", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- body_only=true: no preamble / no @bye --------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("just body") }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check(
    "body_only omits \\input texinfo",
    out:find("\\input texinfo", 1, true) == nil,
    "got: " .. out
  )
  check("body_only omits @bye", out:find("@bye", 1, true) == nil)
  check("body_only still emits body", out:find("just body", 1, true) ~= nil)
end

-- ---- headlines: L1..L4 ----------------------------------------------
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Top") } }),
    A.headline({ level = 2, title = { A.text("Sub") } }),
    A.headline({ level = 3, title = { A.text("Deep") } }),
    A.headline({ level = 4, title = { A.text("Deeper") } }),
  })
  local out = to_texinfo.render(doc)
  check("L1 -> @chapter", out:find("@chapter Top", 1, true) ~= nil, "got: " .. out)
  check("L2 -> @section", out:find("@section Sub", 1, true) ~= nil)
  check("L3 -> @subsection", out:find("@subsection Deep", 1, true) ~= nil)
  check("L4 -> @subsubsection", out:find("@subsubsection Deeper", 1, true) ~= nil)
end

-- ---- headline level >=5 clamps to @subsubsection --------------------
do
  local doc = A.document({
    A.headline({ level = 9, title = { A.text("Way deep") } }),
  })
  local out = to_texinfo.render(doc)
  check(
    "L9 clamps to @subsubsection",
    out:find("@subsubsection Way deep", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- @node emitted before section command ---------------------------
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Intro") } }),
  })
  local out = to_texinfo.render(doc)
  local node_pos = out:find("@node Intro", 1, true)
  local chap_pos = out:find("@chapter Intro", 1, true)
  check(
    "@node line emitted before section command",
    node_pos ~= nil and chap_pos ~= nil and node_pos < chap_pos,
    "got: " .. out
  )
end

-- ---- paragraph: inline then blank line ------------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("Hello world.") }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check(
    "paragraph followed by blank line",
    out:find("Hello world.\n\n", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- emphasis: 6 styles ---------------------------------------------
do
  local doc = A.document({
    A.paragraph({
      A.emphasis("bold", { A.text("B") }),
      A.text(" "),
      A.emphasis("italic", { A.text("I") }),
      A.text(" "),
      A.emphasis("underline", { A.text("U") }),
      A.text(" "),
      A.emphasis("strike", { A.text("S") }),
      A.text(" "),
      A.emphasis("verbatim", { A.text("V") }),
      A.text(" "),
      A.emphasis("code", { A.text("C") }),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("bold -> @strong{}", out:find("@strong{B}", 1, true) ~= nil, "got: " .. out)
  check("italic -> @emph{}", out:find("@emph{I}", 1, true) ~= nil)
  check("underline -> @sansserif{}", out:find("@sansserif{U}", 1, true) ~= nil)
  check("strike -> @strikethrough{}", out:find("@strikethrough{S}", 1, true) ~= nil)
  check("verbatim -> @code{}", out:find("@code{V}", 1, true) ~= nil)
  check("code -> @code{}", out:find("@code{C}", 1, true) ~= nil)
end

-- ---- link with description -> @uref{TARGET, DESC} ------------------
do
  local doc = A.document({
    A.paragraph({
      A.link("https://example.com", { A.text("a link") }),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check(
    "link with desc -> @uref{T, D}",
    out:find("@uref{https://example.com, a link}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- bare link -> @uref{TARGET} -------------------------------------
do
  local doc = A.document({
    A.paragraph({
      A.link("https://naked.example.com"),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check(
    "bare link -> @uref{T}",
    out:find("@uref{https://naked.example.com}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- math: inline + display both -> @math{} -------------------------
do
  local doc = A.document({
    A.paragraph({
      A.text("a "),
      { kind = "math", display = false, body = "x^2" },
      A.text(" b "),
      { kind = "math", display = true, body = "\\int" },
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("inline math -> @math{x^2}", out:find("@math{x^2}", 1, true) ~= nil, "got: " .. out)
  check("display math -> @math{\\int}", out:find("@math{\\int}", 1, true) ~= nil, "got: " .. out)
end

-- ---- linebreak -> @* ------------------------------------------------
do
  local doc = A.document({
    A.paragraph({
      A.text("first"),
      A.linebreak(),
      A.text("second"),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("linebreak emits @*", out:find("first@*second", 1, true) ~= nil, "got: " .. out)
end

-- ---- escape: @ { } -------------------------------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("email@example {brace} end}") }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("@ -> @@", out:find("email@@example", 1, true) ~= nil, "got: " .. out)
  check("{ -> @{", out:find("@{brace@}", 1, true) ~= nil, "got: " .. out)
  check("} -> @}", out:find("end@}", 1, true) ~= nil)
end

-- ---- inline image dropped ------------------------------------------
do
  local doc = A.document({
    A.paragraph({
      A.text("see "),
      { kind = "image", target = "fig.png", alt = "fig" },
      A.text(" here"),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check(
    "inline image dropped (no @image inline)",
    out:find("fig.png", 1, true) == nil,
    "got: " .. out
  )
  check("surrounding text preserved", out:find("see  here", 1, true) ~= nil)
end

-- ---- list (unordered) ----------------------------------------------
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ content = { A.paragraph({ A.text("one") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("two") }) } }),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("itemize begin", out:find("@itemize", 1, true) ~= nil, "got: " .. out)
  check("itemize end", out:find("@end itemize", 1, true) ~= nil)
  check("item one", out:find("@item one", 1, true) ~= nil)
  check("item two", out:find("@item two", 1, true) ~= nil)
end

-- ---- list (ordered) ------------------------------------------------
do
  local doc = A.document({
    A.list(true, {
      A.list_item({ content = { A.paragraph({ A.text("first") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("second") }) } }),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("enumerate begin", out:find("@enumerate", 1, true) ~= nil, "got: " .. out)
  check("enumerate end", out:find("@end enumerate", 1, true) ~= nil)
  check("ordered item first", out:find("@item first", 1, true) ~= nil)
end

-- ---- list (nested) -------------------------------------------------
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
  local out = to_texinfo.render(doc, { body_only = true })
  check("outer item rendered", out:find("@item outer", 1, true) ~= nil, "got: " .. out)
  local _, n_itemize = out:gsub("@itemize", "")
  check("two @itemize from nesting", n_itemize == 2, "got " .. n_itemize)
  check("inner item rendered", out:find("@item inner", 1, true) ~= nil)
end

-- ---- list (checkbox literal prefix) -------------------------------
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ checkbox = "todo", content = { A.paragraph({ A.text("a") }) } }),
      A.list_item({ checkbox = "done", content = { A.paragraph({ A.text("b") }) } }),
      A.list_item({ checkbox = "part", content = { A.paragraph({ A.text("c") }) } }),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("todo checkbox -> [ ]", out:find("@item [ ] a", 1, true) ~= nil, "got: " .. out)
  check("done checkbox -> [X]", out:find("@item [X] b", 1, true) ~= nil)
  check("part checkbox -> [-]", out:find("@item [-] c", 1, true) ~= nil)
end

-- ---- code_block -----------------------------------------------------
do
  local doc = A.document({
    A.code_block("python", 'print("hi")'),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("code_block opens @example", out:find("@example", 1, true) ~= nil, "got: " .. out)
  check("code_block closes @end example", out:find("@end example", 1, true) ~= nil)
  check("code_block body verbatim", out:find('print("hi")', 1, true) ~= nil, "got: " .. out)
end

-- code_block multi-line
do
  local doc = A.document({
    A.code_block("lua", "local x = 1\nprint(x)"),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("code_block line 1", out:find("local x = 1", 1, true) ~= nil)
  check("code_block line 2", out:find("print(x)", 1, true) ~= nil)
end

-- ---- block: example ------------------------------------------------
do
  local doc = A.document({
    A.block("example", { body = "raw text\nline 2" }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check(
    "example as @example",
    out:find("@example", 1, true) ~= nil and out:find("@end example", 1, true) ~= nil,
    "got: " .. out
  )
  check("example body line 1", out:find("raw text", 1, true) ~= nil)
end

-- ---- block: verse --------------------------------------------------
do
  local doc = A.document({
    A.block("verse", { body = "verse 1\nverse 2" }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("verse renders as @example", out:find("@example", 1, true) ~= nil, "got: " .. out)
  check("verse line 1", out:find("verse 1", 1, true) ~= nil)
  check("verse line 2", out:find("verse 2", 1, true) ~= nil)
end

-- ---- block: quote --------------------------------------------------
do
  local doc = A.document({
    A.block("quote", {
      content = {
        A.paragraph({ A.text("first") }),
        A.paragraph({ A.text("second") }),
      },
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("quotation opens", out:find("@quotation", 1, true) ~= nil, "got: " .. out)
  check("quotation closes", out:find("@end quotation", 1, true) ~= nil)
  check(
    "quotation content paragraphs",
    out:find("first", 1, true) ~= nil and out:find("second", 1, true) ~= nil
  )
end

-- ---- block: export dropped -----------------------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    A.block("export", { body = "<html>raw</html>" }),
    A.paragraph({ A.text("after") }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("export body dropped", out:find("<html>raw</html>", 1, true) == nil, "got: " .. out)
  check(
    "paragraphs around export preserved",
    out:find("before", 1, true) ~= nil and out:find("after", 1, true) ~= nil
  )
end

-- ---- table (basic) -------------------------------------------------
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
  local out = to_texinfo.render(doc, { body_only = true })
  check("multitable begin", out:find("@multitable", 1, true) ~= nil, "got: " .. out)
  check("columnfractions present", out:find("@columnfractions", 1, true) ~= nil)
  check("header row uses @item / @tab", out:find("@item name @tab age", 1, true) ~= nil)
  check("data row ada", out:find("@item ada @tab 36", 1, true) ~= nil)
  check("data row ben", out:find("@item ben @tab 41", 1, true) ~= nil)
  check("multitable end", out:find("@end multitable", 1, true) ~= nil)
end

-- ---- table separator rows dropped ---------------------------------
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("h") } }, sep = false },
        { sep = true, cells = {} },
        { cells = { { A.text("a") } }, sep = false },
      },
    },
  })
  local out = to_texinfo.render(doc, { body_only = true })
  -- Expect exactly 2 @item lines (the separator is dropped).
  local _, n_item = out:gsub("@item ", "")
  check(
    "only 2 @item lines (separator dropped)",
    n_item == 2,
    "got " .. n_item .. " @item lines: " .. out
  )
end

-- ---- column fractions sum to ~1 -----------------------------------
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l", "l", "l", "l" },
      rows = {
        {
          cells = {
            { A.text("a") },
            { A.text("b") },
            { A.text("c") },
            { A.text("d") },
          },
          sep = false,
        },
      },
    },
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check(
    "4-column table has 4 .25 fractions",
    out:find("@columnfractions .25 .25 .25 .25", 1, true) ~= nil
      or out:find("@columnfractions .25 .25 .25 .25", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- cell content escaped ----------------------------------------
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("a@b") } }, sep = false },
      },
    },
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("cell content escaped @ -> @@", out:find("@item a@@b", 1, true) ~= nil, "got: " .. out)
end

-- ---- block-level image ----------------------------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    { kind = "image", target = "fig.png", alt = "diagram" },
    A.paragraph({ A.text("after") }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("@image with target", out:find("@image{fig.png", 1, true) ~= nil, "got: " .. out)
  check("@image includes alt text", out:find("diagram", 1, true) ~= nil)
  check(
    "paragraphs around image preserved",
    out:find("before", 1, true) ~= nil and out:find("after", 1, true) ~= nil
  )
end

-- ---- block-level image with no alt --------------------------------
do
  local doc = A.document({ { kind = "image", target = "x.png" } })
  local out = to_texinfo.render(doc, { body_only = true })
  check("@image{x.png} when no alt", out:find("@image{x.png}", 1, true) ~= nil, "got: " .. out)
end

-- ---- horizontal rule ----------------------------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("above") }),
    A.rule(),
    A.paragraph({ A.text("below") }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("rule emits @page", out:find("@page", 1, true) ~= nil, "got: " .. out)
end

-- ---- footnote_definition ------------------------------------------
do
  local doc = A.document({
    A.paragraph({
      A.text("claim"),
      { kind = "footnote_ref", label = "1" },
      A.text("."),
    }),
    A.footnote_definition("1", { A.paragraph({ A.text("the body") }) }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("inline footnote_ref emits [1] literal", out:find("[1]", 1, true) ~= nil, "got: " .. out)
  check("footnote_definition emits [1] body", out:find("[1] the body", 1, true) ~= nil)
end

-- ---- multi-paragraph footnote ------------------------------------
do
  local doc = A.document({
    A.footnote_definition("note", {
      A.paragraph({ A.text("first") }),
      A.paragraph({ A.text("second") }),
    }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check(
    "multi-para footnote: first paragraph after label",
    out:find("[note] first", 1, true) ~= nil,
    "got: " .. out
  )
  check("multi-para footnote: second paragraph rendered", out:find("second", 1, true) ~= nil)
end

-- ---- directive dropped --------------------------------------------
do
  local doc = A.document({
    A.directive("AUTHOR", "Jane"),
    A.paragraph({ A.text("body") }),
  })
  local out = to_texinfo.render(doc, { body_only = true })
  check("AUTHOR not in body", out:find("Jane", 1, true) == nil, "got: " .. out)
  check("paragraph rendered", out:find("body", 1, true) ~= nil)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_texinfo_test: PASS")
os.exit(0)
