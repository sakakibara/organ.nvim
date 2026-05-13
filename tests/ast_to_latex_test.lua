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

-- ---- empty document --------------------------------------------------
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

-- ---- title / author / date directives -------------------------------
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

-- ---- title without author/date --------------------------------------
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

-- ---- body_only -------------------------------------------------------
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

-- ---- headlines map to sectioning commands ----------------------------
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

-- ---- level 9 caps at \subparagraph ----------------------------------
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

-- ---- paragraph emits inline + trailing blank line --------------------
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

-- ---- emphasis (6 styles) --------------------------------------------
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

-- ---- verb delimiter fallback when body contains | -------------------
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

-- ---- link with description ------------------------------------------
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

-- ---- math: inline + display passthrough ------------------------------
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

-- ---- linebreak -> \\ ------------------------------------------------
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

-- ---- inline image ---------------------------------------------------
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

-- ---- LaTeX special char escaping ------------------------------------
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

-- ---- list (unordered) ------------------------------------------------
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

-- ---- list (ordered) --------------------------------------------------
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

-- ---- list (nested) --------------------------------------------------
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

-- ---- list (checkboxes literal prefix) -------------------------------
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

-- ---- code_block ----------------------------------------------------
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

-- ---- block: example ----------------------------------------------
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

-- ---- block: verse -------------------------------------------------
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

-- ---- block: quote -------------------------------------------------
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

-- ---- block: export dropped ---------------------------------------
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

-- ---- table (basic with header divider) ----------------------------
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

-- ---- table column alignment letters -------------------------------
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

-- ---- table with no alignments -> default all l --------------------
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

-- ---- table cell content escaped -----------------------------------
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

-- ---- multi-divider table emits multiple hlines --------------------
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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_latex_test: PASS")
os.exit(0)
