-- Unit tests for organ.ast.to_latex.  Build AST nodes via organ.ast
-- builders, render to LaTeX string, assert via substring matches.
--
-- Run via: nvim --headless -l tests/ast_to_latex_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local A = require("organ.ast")
local to_latex = require("organ.ast.to_latex")

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
  local out = to_latex.render(A.document({}))
  check(
    "\\documentclass{article} present",
    out:find("\\documentclass{article}", 1, true) ~= nil,
    "got: " .. out
  )
  check("\\begin{document} present", out:find("\\begin{document}", 1, true) ~= nil)
  check("\\end{document} present", out:find("\\end{document}", 1, true) ~= nil)
  check(
    "no \\maketitle when no title directive",
    out:find("\\maketitle", 1, true) == nil,
    "got: " .. out
  )
end

-- Title / author / date directives
do
  local doc = A.document({
    A.directive("TITLE", "My Doc"),
    A.directive("AUTHOR", "Sho"),
    A.directive("DATE", "2026-05-02"),
    A.paragraph({ A.text("body") }),
  })
  local out = to_latex.render(doc)
  check(
    "\\title{My Doc} from TITLE directive",
    out:find("\\title{My Doc}", 1, true) ~= nil,
    "got: " .. out
  )
  check("\\author{Sho} from AUTHOR directive", out:find("\\author{Sho}", 1, true) ~= nil)
  check("\\date{2026-05-02} from DATE directive", out:find("\\date{2026-05-02}", 1, true) ~= nil)
  check("\\maketitle present when title set", out:find("\\maketitle", 1, true) ~= nil)
end

-- Title without author/date
do
  local doc = A.document({
    A.directive("TITLE", "Solo"),
    A.paragraph({ A.text("body") }),
  })
  local out = to_latex.render(doc)
  check("\\title{Solo} present", out:find("\\title{Solo}", 1, true) ~= nil, "got: " .. out)
  check("no \\author when absent", out:find("\\author", 1, true) == nil)
  check("no \\date when absent", out:find("\\date", 1, true) == nil)
  check("\\maketitle still present (title set)", out:find("\\maketitle", 1, true) ~= nil)
end

-- body_only
do
  local doc = A.document({
    A.directive("TITLE", "ignored"),
    A.paragraph({ A.text("hello") }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "body_only: no \\documentclass",
    out:find("\\documentclass", 1, true) == nil,
    "got: " .. out
  )
  check("body_only: no \\begin{document}", out:find("\\begin{document}", 1, true) == nil)
  check("body_only: no \\maketitle", out:find("\\maketitle", 1, true) == nil)
  check("body_only: paragraph still rendered", out:find("hello", 1, true) ~= nil)
end

-- Headlines map to sectioning commands
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Top") } }),
    A.headline({ level = 2, title = { A.text("Sub") } }),
    A.headline({ level = 3, title = { A.text("Deep") } }),
    A.headline({ level = 4, title = { A.text("Para") } }),
    A.headline({ level = 5, title = { A.text("Subpara") } }),
  })
  local out = to_latex.render(doc)
  check("level 1 -> \\section{Top}", out:find("\\section{Top}", 1, true) ~= nil, "got: " .. out)
  check("level 2 -> \\subsection{Sub}", out:find("\\subsection{Sub}", 1, true) ~= nil)
  check("level 3 -> \\subsubsection{Deep}", out:find("\\subsubsection{Deep}", 1, true) ~= nil)
  check("level 4 -> \\paragraph{Para}", out:find("\\paragraph{Para}", 1, true) ~= nil)
  check("level 5 -> \\subparagraph{Subpara}", out:find("\\subparagraph{Subpara}", 1, true) ~= nil)
end

-- Level 9 caps at \subparagraph
do
  local doc = A.document({
    A.headline({ level = 9, title = { A.text("Way deep") } }),
  })
  local out = to_latex.render(doc)
  check(
    "level 9 -> \\subparagraph{Way deep}",
    out:find("\\subparagraph{Way deep}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Paragraph emits inline + trailing blank line
do
  local doc = A.document({
    A.paragraph({ A.text("first") }),
    A.paragraph({ A.text("second") }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "two paragraphs separated by blank line",
    out:find("first\n\nsecond", 1, true) ~= nil,
    "got: " .. out
  )
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
  local out = to_latex.render(doc)
  check("bold -> \\textbf{B}", out:find("\\textbf{B}", 1, true) ~= nil, "got: " .. out)
  check("italic -> \\textit{I}", out:find("\\textit{I}", 1, true) ~= nil)
  check("underline -> \\underline{U}", out:find("\\underline{U}", 1, true) ~= nil)
  check("strike -> \\sout{S}", out:find("\\sout{S}", 1, true) ~= nil)
  check("verbatim -> \\verb|V|", out:find("\\verb|V|", 1, true) ~= nil)
  check("code -> \\verb|C|", out:find("\\verb|C|", 1, true) ~= nil)
end

-- Verb delimiter fallback when body contains |
do
  local doc = A.document({
    A.paragraph({
      A.emphasis("code", { A.text("a|b") }),
    }),
  })
  local out = to_latex.render(doc)
  check(
    "verb with | in body falls back to !",
    out:find("\\verb!a|b!", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Link with description
do
  local doc = A.document({
    A.paragraph({
      A.link("https://example.com", { A.text("a link") }),
      A.text(" and "),
      A.link("https://naked.example.com"),
    }),
  })
  local out = to_latex.render(doc)
  check(
    "link w/ desc -> \\href{target}{desc}",
    out:find("\\href{https://example.com}{a link}", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "bare link -> \\href{target}{target}",
    out:find("\\href{https://naked.example.com}{https://naked.example.com}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Math: inline + display passthrough
do
  local doc = A.document({
    A.paragraph({
      A.text("inline: "),
      { kind = "math", display = false, body = "x^2" },
      A.text(" display: "),
      { kind = "math", display = true, body = "\\int_0^1 x" },
    }),
  })
  local out = to_latex.render(doc)
  check("inline math passes through as $x^2$", out:find("$x^2$", 1, true) ~= nil, "got: " .. out)
  check(
    "display math passes through as \\[...\\]",
    out:find("\\[\\int_0^1 x\\]", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Linebreak -> \\
do
  local doc = A.document({
    A.paragraph({
      A.text("first"),
      A.linebreak(),
      A.text("second"),
    }),
  })
  local out = to_latex.render(doc)
  check("linebreak emits \\\\", out:find("first\\\\second", 1, true) ~= nil, "got: " .. out)
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
  local out = to_latex.render(doc)
  check(
    "inline image -> \\includegraphics{fig.png}",
    out:find("\\includegraphics{fig.png}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- LaTeX special char escaping
do
  local doc = A.document({
    A.paragraph({ A.text("50% off & $5 saved #1 a_b <x> {y}") }),
  })
  local out = to_latex.render(doc)
  check("% escaped to \\%", out:find("50\\%", 1, true) ~= nil, "got: " .. out)
  check("& escaped to \\&", out:find("\\&", 1, true) ~= nil)
  check("$ escaped to \\$", out:find("\\$5", 1, true) ~= nil)
  check("# escaped to \\#", out:find("\\#1", 1, true) ~= nil)
  check("_ escaped to \\_", out:find("a\\_b", 1, true) ~= nil)
  check("< escaped to \\textless{}", out:find("\\textless{}", 1, true) ~= nil)
  check("> escaped to \\textgreater{}", out:find("\\textgreater{}", 1, true) ~= nil)
  check("{ escaped to \\{", out:find("\\{y\\}", 1, true) ~= nil)
end

-- List (unordered)
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ content = { A.paragraph({ A.text("one") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("two") }) } }),
    }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check("itemize begin", out:find("\\begin{itemize}", 1, true) ~= nil, "got: " .. out)
  check("itemize end", out:find("\\end{itemize}", 1, true) ~= nil)
  check("item one", out:find("\\item one", 1, true) ~= nil)
  check("item two", out:find("\\item two", 1, true) ~= nil)
end

-- List (ordered)
do
  local doc = A.document({
    A.list(true, {
      A.list_item({ content = { A.paragraph({ A.text("first") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("second") }) } }),
    }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check("enumerate begin", out:find("\\begin{enumerate}", 1, true) ~= nil, "got: " .. out)
  check("enumerate end", out:find("\\end{enumerate}", 1, true) ~= nil)
  check("item first", out:find("\\item first", 1, true) ~= nil)
end

-- List (nested)
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
  local out = to_latex.render(doc, { body_only = true })
  check("outer item rendered", out:find("\\item outer", 1, true) ~= nil, "got: " .. out)
  local _, n_itemize = out:gsub("\\begin{itemize}", "")
  check("nested itemize begin", n_itemize == 2, "expected 2 \\begin{itemize}: " .. out)
  check("inner item rendered", out:find("\\item inner", 1, true) ~= nil)
end

-- List (checkboxes literal prefix)
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ checkbox = "todo", content = { A.paragraph({ A.text("a") }) } }),
      A.list_item({ checkbox = "done", content = { A.paragraph({ A.text("b") }) } }),
      A.list_item({ checkbox = "part", content = { A.paragraph({ A.text("c") }) } }),
    }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check("todo checkbox -> [ ]", out:find("\\item [ ] a", 1, true) ~= nil, "got: " .. out)
  check("done checkbox -> [X]", out:find("\\item [X] b", 1, true) ~= nil)
  check("part checkbox -> [-]", out:find("\\item [-] c", 1, true) ~= nil)
end

-- code_block
do
  local doc = A.document({
    A.code_block("python", 'print("hi")'),
  })
  local out = to_latex.render(doc, { body_only = true })
  check("code_block opens verbatim", out:find("\\begin{verbatim}", 1, true) ~= nil, "got: " .. out)
  check("code_block closes verbatim", out:find("\\end{verbatim}", 1, true) ~= nil)
  check(
    "code_block body raw (no escape inside verbatim)",
    out:find('print("hi")', 1, true) ~= nil,
    "got: " .. out
  )
end

-- code_block with multi-line body
do
  local doc = A.document({
    A.code_block("lua", "local x = 1\nprint(x)"),
  })
  local out = to_latex.render(doc, { body_only = true })
  check("code_block line 1", out:find("local x = 1", 1, true) ~= nil, "got: " .. out)
  check("code_block line 2", out:find("print(x)", 1, true) ~= nil)
end

-- Block: example
do
  local doc = A.document({
    A.block("example", { body = "raw text\nline 2" }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "example as verbatim",
    out:find("\\begin{verbatim}", 1, true) ~= nil
      and out:find("\\end{verbatim}", 1, true) ~= nil
      and out:find("raw text", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Block: verse
do
  local doc = A.document({
    A.block("verse", { body = "verse 1\nverse 2" }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check("verse env opens", out:find("\\begin{verse}", 1, true) ~= nil, "got: " .. out)
  check("verse env closes", out:find("\\end{verse}", 1, true) ~= nil)
  check(
    "verse content lines",
    out:find("verse 1", 1, true) ~= nil and out:find("verse 2", 1, true) ~= nil
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
  local out = to_latex.render(doc, { body_only = true })
  check("quotation env opens", out:find("\\begin{quotation}", 1, true) ~= nil, "got: " .. out)
  check("quotation env closes", out:find("\\end{quotation}", 1, true) ~= nil)
  check(
    "paragraphs inside quotation",
    out:find("first", 1, true) ~= nil and out:find("second", 1, true) ~= nil
  )
end

-- Block: export dropped
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    A.block("export", { body = "<html>raw</html>" }),
    A.paragraph({ A.text("after") }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check("export body dropped", out:find("<html>raw</html>", 1, true) == nil, "got: " .. out)
  check(
    "paragraphs around export preserved",
    out:find("before", 1, true) ~= nil and out:find("after", 1, true) ~= nil
  )
end

-- Table (basic with header divider)
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
  local out = to_latex.render(doc, { body_only = true })
  check(
    "tabular begin with column spec",
    out:find("\\begin{tabular}{ll}", 1, true) ~= nil,
    "got: " .. out
  )
  check("header row separator-terminated", out:find("name & age \\\\", 1, true) ~= nil)
  check("hline after header", out:find("\\hline", 1, true) ~= nil)
  check("data row 1", out:find("ada & 36 \\\\", 1, true) ~= nil)
  check("data row 2", out:find("ben & 41 \\\\", 1, true) ~= nil)
  check("tabular end", out:find("\\end{tabular}", 1, true) ~= nil)
end

-- Table column alignment letters
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l", "c", "r" },
      rows = {
        { cells = { { A.text("a") }, { A.text("b") }, { A.text("c") } }, sep = false },
      },
    },
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "alignment lcr in column spec",
    out:find("\\begin{tabular}{lcr}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Table with no alignments -> default all l
do
  local doc = A.document({
    {
      kind = "table",
      rows = {
        { cells = { { A.text("a") }, { A.text("b") } }, sep = false },
      },
    },
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "default to ll when no alignments",
    out:find("\\begin{tabular}{ll}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Table cell content escaped
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("50%") } }, sep = false },
      },
    },
  })
  local out = to_latex.render(doc, { body_only = true })
  check("cell content latex-escaped", out:find("50\\%", 1, true) ~= nil, "got: " .. out)
end

-- Multi-divider table emits multiple hlines
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("h") } }, sep = false },
        { sep = true, cells = {} },
        { cells = { { A.text("a") } }, sep = false },
        { sep = true, cells = {} },
        { cells = { { A.text("b") } }, sep = false },
      },
    },
  })
  local out = to_latex.render(doc, { body_only = true })
  local _, n_hline = out:gsub("\\hline", "")
  check("two hlines (one per sep)", n_hline == 2, "got " .. n_hline .. " hlines in:\n" .. out)
end

-- Block-level image
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    { kind = "image", target = "fig.png", alt = "diagram" },
    A.paragraph({ A.text("after") }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "block image includegraphics",
    out:find("\\includegraphics{fig.png}", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "block image wrapped in figure",
    out:find("\\begin{figure}", 1, true) ~= nil and out:find("\\end{figure}", 1, true) ~= nil
  )
  check(
    "paragraphs around image preserved",
    out:find("before", 1, true) ~= nil and out:find("after", 1, true) ~= nil
  )
end

-- Block image with no alt -> no caption
do
  local doc = A.document({ { kind = "image", target = "x.png" } })
  local out = to_latex.render(doc, { body_only = true })
  check("image with no alt -> no \\caption", out:find("\\caption{", 1, true) == nil, "got: " .. out)
  check("image still has includegraphics", out:find("\\includegraphics{x.png}", 1, true) ~= nil)
end

-- Horizontal rule
do
  local doc = A.document({
    A.paragraph({ A.text("above") }),
    A.rule(),
    A.paragraph({ A.text("below") }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check("rule renders \\hrule", out:find("\\hrule", 1, true) ~= nil, "got: " .. out)
end

-- footnotes: the body is emitted at the first reference (ox-latex),
-- later references use \ref, definitions are not emitted on their own
do
  local doc = A.document({
    A.paragraph({
      A.text("claim"),
      A.footnote_ref("1"),
      A.text(" and"),
      A.footnote_ref(nil, { A.text("inline text") }),
      A.text(" again"),
      A.footnote_ref("1"),
      A.text("."),
    }),
    A.footnote_definition("1", { A.paragraph({ A.text("the body") }) }),
  })
  local out = to_latex.render(doc)
  check(
    "first reference carries the body and a label",
    out:find("claim\\footnote{the body\\label{fn:1}}", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "inline footnote -> \\footnote{body}",
    out:find("and\\footnote{inline text}", 1, true) ~= nil
  )
  check(
    "later reference -> \\textsuperscript{\\ref{}}",
    out:find("again\\textsuperscript{\\ref{fn:1}}.", 1, true) ~= nil
  )
  check("no \\footnotetext", out:find("\\footnotetext", 1, true) == nil)
  check("no \\footnotemark", out:find("\\footnotemark", 1, true) == nil)
end

-- Multi-paragraph footnote body, single reference: no label
do
  local doc = A.document({
    A.paragraph({ A.text("x"), A.footnote_ref("note") }),
    A.footnote_definition("note", {
      A.paragraph({ A.text("first") }),
      A.paragraph({ A.text("second") }),
    }),
  })
  local out = to_latex.render(doc)
  check(
    "multi-paragraph footnote body",
    out:find("x\\footnote{first\nsecond}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Blank lines inside a verbatim block survive inside a footnote body
do
  local doc = A.document({
    A.paragraph({ A.text("x"), A.footnote_ref("note") }),
    A.footnote_definition("note", {
      A.paragraph({ A.text("para") }),
      A.code_block("lua", "a\n\nb"),
      A.paragraph({ A.text("after") }),
    }),
  })
  local out = to_latex.render(doc)
  check(
    "footnote blocks separated by one newline, verbatim interior kept",
    out:find("x\\footnote{para\n\\begin{verbatim}\na\n\nb\n\\end{verbatim}\nafter}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- A link to a headline whose title holds an anonymous footnote re-renders
-- the title: the body is emitted once, the second occurrence is a \ref
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = { A.text("Heading"), A.footnote_ref(nil, { A.text("a note") }) },
      properties = { CUSTOM_ID = "foo" },
      children = { A.paragraph({ A.text("See "), A.link("#foo"), A.text(" for more.") }) },
    }),
  })
  local ok, out = pcall(to_latex.render, doc, { body_only = true })
  check("anonymous footnote in linked title renders", ok, "got: " .. tostring(out))
  check(
    "anonymous footnote body emitted once with a numbered label",
    ok and out:find("\\section{Heading\\footnote{a note\\label{fn:1}}}", 1, true) ~= nil,
    "got: " .. tostring(out)
  )
  check(
    "re-rendered title refers to the numbered label",
    ok and out:find("\\hyperref[sec:foo]{Heading\\textsuperscript{\\ref{fn:1}}}", 1, true) ~= nil,
    "got: " .. tostring(out)
  )
end

-- Every block kind inside a list item renders
do
  local doc = A.document({
    A.list(false, {
      A.list_item({
        content = {
          A.paragraph({ A.text("intro") }),
          A.code_block("lua", "print(1)"),
        },
      }),
    }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "code block inside an item",
    out:find("\\item intro\n\\begin{verbatim}\nprint(1)\n\\end{verbatim}\n\\end{itemize}", 1, true)
      ~= nil,
    "got: " .. out
  )
end

-- A nested list closing an item is followed directly by the next \item
do
  local doc = A.document({
    A.list(false, {
      A.list_item({
        content = {
          A.paragraph({ A.text("outer") }),
          A.list(false, { A.list_item({ content = { A.paragraph({ A.text("inner") }) } }) }),
        },
      }),
      A.list_item({ content = { A.paragraph({ A.text("next") }) } }),
    }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "no blank line between a nested list and the next item",
    out:find("\\item inner\n\\end{itemize}\n\\item next\n\\end{itemize}", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Internal links -> \hyperref with \label on headlines and targets
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Target heading") } }),
    A.headline({ level = 1, title = { A.text("Custom") }, properties = { CUSTOM_ID = "custom" } }),
    A.paragraph({ A.text("see "), A.target("anchor"), A.text(" here") }),
    A.paragraph({
      A.link("file:notes.org", { A.text("Notes") }),
      A.text(" "),
      A.link("*Target heading", { A.text("internal") }),
      A.text(" "),
      A.link("#custom", { A.text("by id") }),
      A.text(" "),
      A.link("anchor", { A.text("to target") }),
      A.text(" "),
      A.link("anchor"),
      A.text(" "),
      A.link("*Missing", { A.text("gone") }),
      A.text(" "),
      A.link("https://x.y/a?b=1", { A.text("q") }),
    }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "headline gets \\label{sec:...}",
    out:find("\\section{Target heading}\n\\label{sec:target-heading}", 1, true) ~= nil,
    "got: " .. out
  )
  check("CUSTOM_ID label", out:find("\\section{Custom}\n\\label{sec:custom}", 1, true) ~= nil)
  check("file: prefix stripped", out:find("\\href{notes.org}{Notes}", 1, true) ~= nil)
  check(
    "*Title -> \\hyperref[sec:]",
    out:find("\\hyperref[sec:target-heading]{internal}", 1, true) ~= nil
  )
  check(
    "#custom -> \\hyperref[sec:custom]",
    out:find("\\hyperref[sec:custom]{by id}", 1, true) ~= nil
  )
  check("target -> \\hyperref[name]", out:find("\\hyperref[anchor]{to target}", 1, true) ~= nil)
  check("target without description -> \\ref", out:find("\\ref{anchor}", 1, true) ~= nil)
  check("unresolved -> \\texttt{desc}", out:find("\\texttt{gone}", 1, true) ~= nil)
  check("external kept", out:find("\\href{https://x.y/a?b=1}{q}", 1, true) ~= nil)
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
      A.text(" "),
      A.entity("beta"),
      A.entity("gamma"),
      A.text("x"),
    }),
  })
  local out = to_latex.render(doc, { body_only = true })
  check(
    "latex subscript -> \\textsubscript",
    out:find("H\\textsubscript{2}O", 1, true) ~= nil,
    "got: " .. out
  )
  check("latex superscript -> \\textsuperscript", out:find("x\\textsuperscript{2}", 1, true) ~= nil)
  check("latex entity -> latex command", out:find("\\textcopyright{}", 1, true) ~= nil)
  check("latex math entity wrapped in \\( \\)", out:find(" \\(\\alpha\\) ", 1, true) ~= nil)
  check(
    "adjacent math entities share one math block",
    out:find(" \\(\\beta\\gamma\\)x", 1, true) ~= nil
  )
  check("latex cookie verbatim, % escaped", out:find("[2/3] [50\\%]", 1, true) ~= nil)
  check(
    "latex timestamp -> \\textit",
    out:find("\\textit{\\textless{}2026-09-10 Thu\\textgreater{}}", 1, true) ~= nil
  )
  check("latex target -> \\label", out:find("\\label{anchor}", 1, true) ~= nil)
  check("latex macro kept as escaped text", out:find("\\{\\{\\{title\\}\\}\\}", 1, true) ~= nil)
  check(
    "latex unknown entity passed through as a LaTeX macro",
    out:find(" \\nosuchentity ", 1, true) ~= nil
      and out:find("\\textbackslash{}nosuchentity", 1, true) == nil
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_latex_test: PASS")
os.exit(0)
