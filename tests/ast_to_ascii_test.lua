-- Unit tests for organ.ast.to_ascii.  Build AST nodes via organ.ast
-- builders, render to ASCII string, assert via substring matches.
--
-- Run via: nvim --headless -l tests/ast_to_ascii_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local A = require("organ.ast")
local to_ascii = require("organ.ast.to_ascii")

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
  local out = to_ascii.render(A.document({}))
  check("empty doc renders to single newline", out == "\n", "got: " .. vim.inspect(out))
end

-- Headlines (per-level underlines)
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Top") } }),
    A.headline({ level = 2, title = { A.text("Sub") } }),
    A.headline({ level = 3, title = { A.text("Deeper") } }),
  })
  local out = to_ascii.render(doc)
  check("level 1 underlined with =", out:find("Top\n===", 1, true) ~= nil, "got: " .. out)
  check("level 2 underlined with -", out:find("Sub\n---", 1, true) ~= nil)
  check("level 3 underlined with ~", out:find("Deeper\n~~~~~~", 1, true) ~= nil)
end

-- Paragraph
do
  local doc = A.document({
    A.paragraph({ A.text("simple text") }),
  })
  local out = to_ascii.render(doc)
  check("paragraph renders plain", out:find("simple text", 1, true) ~= nil, "got: " .. out)
end

-- Inline emphasis stripped
do
  local doc = A.document({
    A.paragraph({
      A.text("a "),
      A.emphasis("bold", { A.text("bold") }),
      A.text(" b "),
      A.emphasis("italic", { A.text("italic") }),
      A.text(" c "),
      A.emphasis("verbatim", { A.text("verb") }),
      A.text("."),
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "emphasis stripped, content preserved",
    out:find("a bold b italic c verb.", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Inline link with description
do
  local doc = A.document({
    A.paragraph({
      A.text("See "),
      A.link("https://x", { A.text("a link") }),
      A.text("."),
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "link rendered as 'text (url)'",
    out:find("See a link (https://x).", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Bare link (no description)
do
  local doc = A.document({
    A.paragraph({
      A.text("plain "),
      A.link("https://y"),
      A.text(" end"),
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "bare link rendered as bare url",
    out:find("plain https://y end", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Math (rendered as body, no $ delimiters)
do
  local doc = A.document({
    A.paragraph({
      A.text("see "),
      { kind = "math", display = false, body = "x^2" },
      A.text(" and "),
      { kind = "math", display = true, body = "\\int" },
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "math keeps its delimiters",
    out:find("see $x^2$ and $$\\int$$", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Inline image
do
  local doc = A.document({
    A.paragraph({
      A.text("before "),
      { kind = "image", target = "fig.png", alt = "fig" },
      A.text(" after"),
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "inline image with description -> desc (target)",
    out:find("before fig (fig.png) after", 1, true) ~= nil,
    "got: " .. out
  )
end

-- footnote_ref dropped
do
  local doc = A.document({
    A.paragraph({
      A.text("claim"),
      { kind = "footnote_ref", label = "1" },
      A.text("."),
    }),
  })
  local out = to_ascii.render(doc)
  check("footnote_ref dropped", out:find("claim.", 1, true) ~= nil, "got: " .. out)
end

-- List (unordered, basic)
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ content = { A.paragraph({ A.text("one") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("two") }) } }),
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "unordered list - one / - two",
    out:find("- one", 1, true) ~= nil and out:find("- two", 1, true) ~= nil,
    "got: " .. out
  )
end

-- List (ordered: numbered)
do
  local doc = A.document({
    A.list(true, {
      A.list_item({ content = { A.paragraph({ A.text("alpha") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("beta") }) } }),
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "ordered list keeps its numbering",
    out:find("1. alpha", 1, true) ~= nil and out:find("2. beta", 1, true) ~= nil,
    "got: " .. out
  )
end

-- List (checkboxes preserved as [X]/[ ]/[-])
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ checkbox = "todo", content = { A.paragraph({ A.text("a") }) } }),
      A.list_item({ checkbox = "done", content = { A.paragraph({ A.text("b") }) } }),
      A.list_item({ checkbox = "part", content = { A.paragraph({ A.text("c") }) } }),
    }),
  })
  local out = to_ascii.render(doc)
  check("todo checkbox -> [ ]", out:find("- [ ] a", 1, true) ~= nil, "got: " .. out)
  check("done checkbox -> [X]", out:find("- [X] b", 1, true) ~= nil)
  check("partial checkbox -> [-]", out:find("- [-] c", 1, true) ~= nil)
end

-- List (nested 2-space indent)
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
  local out = to_ascii.render(doc)
  check("outer at column 0", out:find("- outer", 1, true) ~= nil, "got: " .. out)
  check("inner indented 2 spaces", out:find("  - inner", 1, true) ~= nil)
end

-- code_block: boxed, language not shown (org-ascii-src-block).
do
  local doc = A.document({
    A.code_block("python", "print('hi')"),
  })
  local out = to_ascii.render(doc)
  check("code body boxed", out:find(",----\n| print('hi')\n`----", 1, true) ~= nil, "got: " .. out)
  check("code language is not shown", out:find("python", 1, true) == nil, "got: " .. out)
end

-- Multi-line code preserves line breaks, each line inside the box.
do
  local doc = A.document({
    A.code_block("lua", "local x = 1\nprint(x)"),
  })
  local out = to_ascii.render(doc)
  check("multi-line code: line 1 boxed", out:find("| local x = 1", 1, true) ~= nil, "got: " .. out)
  check("multi-line code: line 2 boxed", out:find("| print(x)", 1, true) ~= nil)
end

-- Block: example.  ox-ascii boxes an example block exactly as it boxes
-- fixed-width lines and source blocks.
do
  local doc = A.document({
    A.block("example", { body = "raw text\nline 2" }),
  })
  local out = to_ascii.render(doc)
  check(
    "example boxed",
    out:find(",----\n| raw text\n| line 2\n`----", 1, true) ~= nil,
    "got: " .. out
  )
  check("example is not indented instead", out:find("    raw text", 1, true) == nil, "got: " .. out)
end

-- Block: verse
do
  local doc = A.document({
    A.block("verse", { body = "v1\nv2" }),
  })
  local out = to_ascii.render(doc)
  check("verse indented like example", out:find("    v1", 1, true) ~= nil, "got: " .. out)
  check("verse line 2 indented", out:find("    v2", 1, true) ~= nil)
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
  local out = to_ascii.render(doc)
  check("quote line 1 prefixed with '  > '", out:find("  > first", 1, true) ~= nil, "got: " .. out)
  check("quote line 2 prefixed with '  > '", out:find("  > second", 1, true) ~= nil)
end

-- Block: export (dropped)
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    A.block("export", { body = "<html>" }),
    A.paragraph({ A.text("after") }),
  })
  local out = to_ascii.render(doc)
  check("export block dropped", out:find("<html>", 1, true) == nil, "got: " .. out)
  check(
    "paragraphs around export still present",
    out:find("before", 1, true) ~= nil and out:find("after", 1, true) ~= nil
  )
end

-- Table (basic)
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
  local out = to_ascii.render(doc)
  check("top divider present", out:find("+------+-----+", 1, true) ~= nil, "got: " .. out)
  check("header row", out:find("| name | age |", 1, true) ~= nil)
  check("data row 1", out:find("| ada  | 36  |", 1, true) ~= nil)
  check("data row 2", out:find("| ben  | 41  |", 1, true) ~= nil)
end

-- Table (multi-divider preserves them all)
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("section a") } }, sep = false },
        { sep = true, cells = {} },
        { cells = { { A.text("a1") } }, sep = false },
        { sep = true, cells = {} },
        { cells = { { A.text("a2") } }, sep = false },
      },
    },
  })
  local out = to_ascii.render(doc)
  local divider_count = 0
  for _ in out:gmatch("+%-+%+") do
    divider_count = divider_count + 1
  end
  -- top + header-sep + middle-sep + bottom = 4 dividers minimum.
  check(
    "at least 4 dividers (top + 2 mid-seps + bottom)",
    divider_count >= 4,
    "got " .. divider_count .. " in:\n" .. out
  )
  check("a1 still rendered", out:find("| a1", 1, true) ~= nil)
  check("a2 still rendered", out:find("| a2", 1, true) ~= nil)
end

-- Table (column widths fit widest cell)
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("short") } }, sep = false },
        { cells = { { A.text("much longer cell") } }, sep = false },
      },
    },
  })
  local out = to_ascii.render(doc)
  -- The divider width should accommodate "much longer cell" (16 chars) + 2 space pad = 18 dashes.
  check(
    "column widened to longest cell",
    out:find("+" .. string.rep("-", 18) .. "+", 1, true) ~= nil,
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
  local out = to_ascii.render(doc)
  check(
    "block image with description -> desc (target)",
    out:find("diagram (fig.png)", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "paragraphs around image still present",
    out:find("before", 1, true) ~= nil and out:find("after", 1, true) ~= nil
  )
end

-- Horizontal rule
do
  local doc = A.document({
    A.paragraph({ A.text("above") }),
    A.rule(),
    A.paragraph({ A.text("below") }),
  })
  local out = to_ascii.render(doc)
  check(
    "rule renders as 60 dashes",
    out:find("\n" .. string.rep("-", 60) .. "\n", 1, true) ~= nil,
    "got: " .. out
  )
end

-- footnote_definition
do
  local doc = A.document({
    A.paragraph({ A.text("claim") }),
    A.footnote_definition("1", { A.paragraph({ A.text("the footnote body") }) }),
  })
  local out = to_ascii.render(doc)
  check(
    "footnote def includes label and body",
    out:find("[1] the footnote body", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Multi-paragraph footnote: subsequent paragraphs indent 4 spaces.
do
  local doc = A.document({
    A.footnote_definition("note", {
      A.paragraph({ A.text("first") }),
      A.paragraph({ A.text("second") }),
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "footnote first paragraph after label",
    out:find("[note] first", 1, true) ~= nil,
    "got: " .. out
  )
  check("footnote second paragraph indented 4 spaces", out:find("    second", 1, true) ~= nil)
end

-- Directive: dropped
do
  local doc = A.document({
    A.directive("TITLE", "My Doc"),
    A.directive("AUTHOR", "Jane"),
    A.paragraph({ A.text("body") }),
  })
  local out = to_ascii.render(doc)
  check("directive TITLE dropped", out:find("My Doc", 1, true) == nil, "got: " .. out)
  check("directive AUTHOR dropped", out:find("Jane", 1, true) == nil)
  check("paragraph still rendered", out:find("body", 1, true) ~= nil)
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
  local out = to_ascii.render(doc)
  check("ascii subscript -> _x", out:find("H_2O", 1, true) ~= nil, "got: " .. out)
  check("ascii superscript -> ^x", out:find("x^2", 1, true) ~= nil)
  check("ascii entity -> ascii form", out:find("(c) alpha", 1, true) ~= nil)
  check("ascii cookie verbatim", out:find("[2/3] [50%]", 1, true) ~= nil)
  check("ascii timestamp verbatim", out:find("<2026-09-10 Thu>", 1, true) ~= nil)
  check("ascii target dropped", out:find("anchor", 1, true) == nil)
  check("ascii macro kept as text", out:find("{{{title}}}", 1, true) ~= nil)
  check("ascii unknown entity kept as text", out:find("\\nosuchentity", 1, true) ~= nil)
end

-- Fixed-width lines (`: text`) -- every short babel result is one.
do
  local doc = A.document({ { kind = "fixed_width", body = "42\nnext" } })
  local out = to_ascii.render(doc)
  check(
    "fixed_width -> boxed",
    out:find(",----\n| 42\n| next\n`----", 1, true) ~= nil,
    "got: " .. out
  )
end

-- LaTeX environments pass through.
do
  local body = "\\begin{equation}\nx = 1\n\\end{equation}"
  local doc = A.document({ { kind = "latex_environment", name = "equation", body = body } })
  check("latex_environment passes through", to_ascii.render(doc):find(body, 1, true) ~= nil)
end

-- Greater blocks: center, and backend-gated export blocks.
do
  local doc = A.document({
    A.block("center", { content = { A.paragraph({ A.text("mid") }) } }),
    A.block("export", { backend = "ascii", body = "raw ascii" }),
    A.block("export", { backend = "html", body = "<b>x</b>" }),
  })
  local out = to_ascii.render(doc)
  check(
    "center block is centred",
    out:find(string.rep(" ", 34) .. "mid", 1, true) ~= nil,
    "got: " .. out
  )
  check("export ascii passes through", out:find("raw ascii", 1, true) ~= nil)
  check("export html is dropped", out:find("<b>x</b>", 1, true) == nil)
end

-- TODO keyword, priority cookie and tags reach the title line.
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
  })
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_priority = true,
    with_toc = false,
  })
  local out = to_ascii.render(doc)
  check(
    "title line carries number, todo, priority and flushed tags",
    out:find("1 TODO (#A) Task one", 1, true) ~= nil and out:find(":work:urgent:", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "tags are flushed right to the text width",
    out:match("^[^\n]*") and #(out:match("^[^\n]*")) == 72,
    "got: " .. out
  )
end

-- Description lists keep their terms.
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ tag = { A.text("term") }, content = { A.paragraph({ A.text("definition") }) } }),
    }),
  })
  check(
    "description term on its own line",
    to_ascii.render(doc):find("term\n  definition", 1, true) ~= nil,
    "got: " .. to_ascii.render(doc)
  )
end

-- Headlines past the underline set still get a rule.
do
  local doc = A.document({ A.headline({ level = 6, title = { A.text("Six") } }) })
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_toc = false,
    with_section_numbers = false,
    headline_levels = 6,
  })
  check(
    "level 6 is underlined",
    to_ascii.render(doc):find("Six\n===", 1, true) ~= nil,
    "got: " .. to_ascii.render(doc)
  )
end

-- A list item may hold more than paragraphs.
do
  local doc = A.document({
    A.list(false, {
      A.list_item({
        content = {
          A.paragraph({ A.text("item") }),
          A.code_block("lua", "print(1)"),
        },
      }),
    }),
  })
  check(
    "src block inside a list item survives",
    to_ascii.render(doc):find("print(1)", 1, true) ~= nil,
    "got: " .. to_ascii.render(doc)
  )
end

-- Captions print under the element they belong to.
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      affiliated = { { name = "CAPTION", value = "Cap", inline = { A.text("Cap") } } },
      rows = { { cells = { { A.text("a") } }, sep = false } },
    },
  })
  check(
    "table caption",
    to_ascii.render(doc):find("Table 1: Cap", 1, true) ~= nil,
    "got: " .. to_ascii.render(doc)
  )
end

-- Table of contents.
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = { A.text("One") },
      children = { A.headline({ level = 2, title = { A.text("Deep") } }) },
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "toc heading",
    out:find("Table of Contents\n_________________", 1, true) ~= nil,
    "got: " .. out
  )
  check("toc entry", out:find("1. One", 1, true) ~= nil)
  check("toc nests", out:find(".. 1. Deep", 1, true) ~= nil)

  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_toc = false,
  })
  check("toc:nil suppresses it", to_ascii.render(doc):find("Table of Contents", 1, true) == nil)
end

-- Alignment cookies are metadata, not a data row.
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "r", "l" },
      rows = {
        { cells = { { A.text("<r>") }, { A.text("<l>") } }, sep = false },
        { cells = { { A.text("x") }, { A.text("a") } }, sep = false },
      },
    },
  })
  check(
    "cookie row is not rendered",
    to_ascii.render(doc):find("<r>", 1, true) == nil,
    "got: " .. to_ascii.render(doc)
  )
end

-- Entities keep working with the `{}` terminator.
do
  local doc = A.document({ A.paragraph({ A.entity("alpha{}"), A.text("text") }) })
  check("\\alpha{} is the alpha entity", to_ascii.render(doc):find("alphatext", 1, true) ~= nil)
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
  local out = to_ascii.render(doc)
  check("H:2 keeps level 2 underlined", out:find("Sub\n---", 1, true) ~= nil, "got: " .. out)
  check("H:2 demotes level 3 to a bullet", out:find("- Deep\n", 1, true) ~= nil, "got: " .. out)
  check("H:2 indents the demoted body", out:find("\n  body\n", 1, true) ~= nil, "got: " .. out)
  check("H:2 indents the level 4 bullet", out:find("\n  - Deeper", 1, true) ~= nil, "got: " .. out)
  check(
    "sibling demoted headline is a sibling bullet",
    out:find("\n- Deep B", 1, true) ~= nil,
    "got: " .. out
  )

  -- ox-ascii bullets a demoted headline either way, with the section
  -- number inside the title.
  local numbered = tree()
  numbered.options = opts({ with_section_numbers = true })
  local nout = to_ascii.render(numbered)
  check(
    "num:t keeps the bullet and numbers the title",
    nout:find("- 1.1.1 Deep", 1, true) ~= nil,
    "got: " .. nout
  )
  check(
    "num:t numbers the nested title",
    nout:find("- 1.1.1.1 Deeper", 1, true) ~= nil,
    "got: " .. nout
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

  local out = to_ascii.render(from_org.from_lines(src))
  check(
    "#+TOC: headlines builds the document TOC under toc:nil",
    out:find("Table of Contents", 1, true) ~= nil and out:find("1. One", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "#+TOC: headlines 2 stops at level 2",
    out:find("Three\n", 1, true) ~= nil and select(2, out:gsub("Three", "")) == 1,
    "got: " .. out
  )
  check(
    "#+TOC: tables lists the captioned table",
    out:find("List of Tables\n______________\n\nTable 1: Table one", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "#+TOC: listings lists the captioned src block",
    out:find("List of Listings\n________________\n\nListing 1: Listing one", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "#+TOC: figures renders nothing, as in ox-ascii",
    out:find("List of Figures", 1, true) == nil
  )
  check(
    "#+TOC: ... local keeps the absolute outline indent",
    out:find(".. 1. Five", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ox-ascii boxes all three verbatim forms identically -- `: ` lines,
-- `#+begin_example` and a source block, with or without a language.
-- Emacs 30.2 / Org 9.7.11 on
--   : one / : two
--   #+BEGIN_EXAMPLE ... #+BEGIN_SRC lua ... #+BEGIN_SRC
-- prints ",----" / "| <line>" / "`----" for each.
do
  local from_org = require("organ.ast.from_org")
  local function body(lines)
    return to_ascii.render(from_org.from_lines(lines))
  end
  local boxed = ",----\n| one\n| two\n`----"
  check(
    "fixed-width lines are boxed",
    body({ ": one", ": two" }):find(boxed, 1, true) ~= nil,
    "got: " .. body({ ": one", ": two" })
  )
  local ex = body({ "#+BEGIN_EXAMPLE", "one", "two", "#+END_EXAMPLE" })
  check("an example block is boxed the same way", ex:find(boxed, 1, true) ~= nil, "got: " .. ex)
  local src = body({ "#+BEGIN_SRC lua", "one", "two", "#+END_SRC" })
  check("a source block is boxed the same way", src:find(boxed, 1, true) ~= nil, "got: " .. src)
  check("a source block's language is not printed", src:find("lua", 1, true) == nil, "got: " .. src)
  local nolang = body({ "#+BEGIN_SRC", "one", "two", "#+END_SRC" })
  check(
    "a source block without a language is boxed too",
    nolang:find(boxed, 1, true) ~= nil,
    "got: " .. nolang
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_ascii_test: PASS")
os.exit(0)
