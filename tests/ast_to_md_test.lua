-- Unit tests for organ.ast.to_md.  Hand-built ASTs are fed directly
-- to M.render; no from_org involvement, no tree-sitter.
--
-- Run via: nvim --headless -l tests/ast_to_md_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local A = require("organ.ast")
local to_md = require("organ.ast.to_md")

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
  local doc = A.document({})
  local out = to_md.render(doc)
  check("empty doc renders to a single newline", out == "\n", "got " .. vim.inspect(out))
end

-- Headlines (ATX, levels 1-6)
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Top") } }),
    A.headline({ level = 2, title = { A.text("Sub") } }),
    A.headline({ level = 3, title = { A.text("Deep") } }),
  })
  local out = to_md.render(doc)
  check("headline level 1 -> '# Top'", out:find("# Top", 1, true) ~= nil)
  check("headline level 2 -> '## Sub'", out:find("## Sub", 1, true) ~= nil)
  check("headline level 3 -> '### Deep'", out:find("### Deep", 1, true) ~= nil)
end

-- Levels beyond 6 clamp.
do
  local doc = A.document({
    A.headline({ level = 8, title = { A.text("Way deep") } }),
  })
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    headline_levels = 8,
  })
  local out = to_md.render(doc)
  check("level 8 clamps to 6 hashes", out:find("###### Way deep", 1, true) ~= nil, "got: " .. out)
end

-- Paragraph + text inline
do
  local doc = A.document({
    A.paragraph({ A.text("Hello world.") }),
  })
  local out = to_md.render(doc)
  check("paragraph renders text", out:find("Hello world.", 1, true) ~= nil)
end

-- Headline followed by paragraph: blank line between them.
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("H") } }),
    A.paragraph({ A.text("body") }),
  })
  local out = to_md.render(doc)
  check(
    "headline then paragraph: both present",
    out:find("# H", 1, true) ~= nil and out:find("body", 1, true) ~= nil,
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
  local out = to_md.render(doc)
  check("bold -> **B**", out:find("**B**", 1, true) ~= nil)
  check("italic -> *I*", out:find("*I*", 1, true) ~= nil)
  check("underline -> <u>U</u>", out:find("<u>U</u>", 1, true) ~= nil)
  check("strike -> ~~S~~", out:find("~~S~~", 1, true) ~= nil)
  check("verbatim -> `V`", out:find("`V`", 1, true) ~= nil)
  check("code -> `C`", out:find("`C`", 1, true) ~= nil)
end

-- Nested emphasis: bold inside italic should round-trip.
do
  local doc = A.document({
    A.paragraph({
      A.emphasis("italic", {
        A.text("outer "),
        A.emphasis("bold", { A.text("inner") }),
      }),
    }),
  })
  local out = to_md.render(doc)
  check("nested bold inside italic", out:find("*outer **inner***", 1, true) ~= nil, "got: " .. out)
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
  local out = to_md.render(doc)
  check(
    "link with description",
    out:find("[a link](https://example.com)", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "naked link",
    out:find("[https://naked.example.com](https://naked.example.com)", 1, true) ~= nil
  )
end

-- Inline image (within paragraph)
do
  local doc = A.document({
    A.paragraph({
      A.text("See "),
      { kind = "image", target = "fig.png", alt = "fig" },
      A.text(" here."),
    }),
  })
  local out = to_md.render(doc)
  check(
    "inline image with description -> hyperlink",
    out:find("[fig](fig.png)", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Inline footnote_ref
do
  local doc = A.document({
    A.paragraph({
      A.text("claim"),
      { kind = "footnote_ref", label = "1" },
      A.text("."),
    }),
  })
  local out = to_md.render(doc)
  check("footnote_ref -> [^1]", out:find("[^1]", 1, true) ~= nil, "got: " .. out)
end

-- Inline math (inline + display)
do
  local doc = A.document({
    A.paragraph({
      A.text("inline: "),
      { kind = "math", display = false, body = "x^2" },
      A.text(" display: "),
      { kind = "math", display = true, body = "\\int_0^1 x dx" },
    }),
  })
  local out = to_md.render(doc)
  check("inline math -> $x^2$", out:find("$x^2$", 1, true) ~= nil)
  check("display math -> $$...$$", out:find("$$\\int_0^1 x dx$$", 1, true) ~= nil, "got: " .. out)
end

-- Linebreak
do
  local doc = A.document({
    A.paragraph({
      A.text("first"),
      A.linebreak(),
      A.text("second"),
    }),
  })
  local out = to_md.render(doc)
  -- A markdown hard line break is "  \n" (two trailing spaces + newline).
  check(
    "linebreak emits two-space + newline",
    out:find("first  \nsecond", 1, true) ~= nil,
    "got: " .. vim.inspect(out)
  )
end

-- List (unordered, basic)
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ content = { A.paragraph({ A.text("one") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("two") }) } }),
    }),
  })
  local out = to_md.render(doc)
  check(
    "unordered list - one / - two",
    out:find("- one", 1, true) ~= nil and out:find("- two", 1, true) ~= nil,
    "got: " .. out
  )
end

-- List (ordered, basic)
do
  local doc = A.document({
    A.list(true, {
      A.list_item({ content = { A.paragraph({ A.text("alpha") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("beta") }) } }),
    }),
  })
  local out = to_md.render(doc)
  check(
    "ordered list 1. / 2.",
    out:find("1. alpha", 1, true) ~= nil and out:find("2. beta", 1, true) ~= nil,
    "got: " .. out
  )
end

-- List (checkboxes)
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ checkbox = "todo", content = { A.paragraph({ A.text("a") }) } }),
      A.list_item({ checkbox = "done", content = { A.paragraph({ A.text("b") }) } }),
      A.list_item({ checkbox = "part", content = { A.paragraph({ A.text("c") }) } }),
    }),
  })
  local out = to_md.render(doc)
  check("todo checkbox -> [ ]", out:find("- [ ] a", 1, true) ~= nil, "got: " .. out)
  check("done checkbox -> [x]", out:find("- [x] b", 1, true) ~= nil)
  check("partial checkbox -> [-]", out:find("- [-] c", 1, true) ~= nil)
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
  local out = to_md.render(doc)
  check("outer at column 0", out:find("- outer", 1, true) ~= nil, "got: " .. out)
  check("inner indented 2 spaces", out:find("  - inner", 1, true) ~= nil)
end

-- code_block
do
  local doc = A.document({
    A.code_block("python", "print('hi')"),
  })
  local out = to_md.render(doc)
  check(
    "fenced code with language",
    out:find("```python\nprint('hi')\n```", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Code block with no language: still fenced.
do
  local doc = A.document({
    A.code_block(nil, "raw"),
  })
  local out = to_md.render(doc)
  check("fenced code no language", out:find("```\nraw\n```", 1, true) ~= nil, "got: " .. out)
end

-- Multi-line code preserves body verbatim.
do
  local doc = A.document({
    A.code_block("lua", "local x = 1\nprint(x)"),
  })
  local out = to_md.render(doc)
  check(
    "multi-line code preserves newlines",
    out:find("```lua\nlocal x = 1\nprint(x)\n```", 1, true) ~= nil
  )
end

-- Block: quote
do
  local doc = A.document({
    A.block("quote", { content = { A.paragraph({ A.text("wisdom") }) } }),
  })
  local out = to_md.render(doc)
  check("quote -> '> wisdom'", out:find("> wisdom", 1, true) ~= nil, "got: " .. out)
end

-- Multi-line quote: each line prefixed with '> '.
do
  local doc = A.document({
    A.block("quote", {
      content = {
        A.paragraph({ A.text("line one") }),
        A.paragraph({ A.text("line two") }),
      },
    }),
  })
  local out = to_md.render(doc)
  check(
    "multi-paragraph quote: both prefixed",
    out:find("> line one", 1, true) ~= nil and out:find("> line two", 1, true) ~= nil
  )
end

-- Block: example / verse (body as fenced code)
do
  local doc = A.document({
    A.block("example", { body = "raw text\nline 2" }),
  })
  local out = to_md.render(doc)
  check(
    "example -> indented block",
    out:find("    raw text\n    line 2", 1, true) ~= nil,
    "got: " .. out
  )
end

do
  local doc = A.document({
    A.block("verse", { body = "verse 1\nverse 2" }),
  })
  local out = to_md.render(doc)
  check(
    "verse -> <p class=verse>",
    out:find('<p class="verse">\nverse 1<br />\nverse 2<br />\n</p>', 1, true) ~= nil
  )
end

-- Block: export (dropped)
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    A.block("export", { body = "<html>" }),
    A.paragraph({ A.text("after") }),
  })
  local out = to_md.render(doc)
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
        { cells = { { A.text("Alice") }, { A.text("30") } }, sep = false },
        { cells = { { A.text("Bob") }, { A.text("25") } }, sep = false },
      },
    },
  })
  local out = to_md.render(doc)
  check("header row", out:find("| name | age |", 1, true) ~= nil, "got: " .. out)
  check("divider row", out:find("| --- | ---: |", 1, true) ~= nil)
  check("data row 1", out:find("| Alice | 30 |", 1, true) ~= nil)
  check("data row 2", out:find("| Bob | 25 |", 1, true) ~= nil)
end

-- Multi-divider org tables: keep only the first divider, drop later ones.
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l" },
      rows = {
        { cells = { { A.text("section a") } }, sep = false },
        { sep = true, cells = {} },
        { cells = { { A.text("a1") } }, sep = false },
        { sep = true, cells = {} }, -- mid-table separator: should be dropped
        { cells = { { A.text("a2") } }, sep = false },
      },
    },
  })
  local out = to_md.render(doc)
  local divider_count = 0
  for _ in out:gmatch("| %-%-%- |") do
    divider_count = divider_count + 1
  end
  check(
    "only one divider survives flatten",
    divider_count == 1,
    "got " .. divider_count .. " dividers in:\n" .. out
  )
  -- Data rows still present.
  check("a1 still rendered", out:find("| a1 |", 1, true) ~= nil)
  check("a2 still rendered", out:find("| a2 |", 1, true) ~= nil)
end

-- Block-level image
do
  local doc = A.document({
    A.paragraph({ A.text("before") }),
    { kind = "image", target = "fig.png", alt = "diagram" },
    A.paragraph({ A.text("after") }),
  })
  local out = to_md.render(doc)
  check(
    "block image with description -> hyperlink",
    out:find("[diagram](fig.png)", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Image without alt falls back to target as alt text.
do
  local doc = A.document({
    { kind = "image", target = "x.png" },
  })
  local out = to_md.render(doc)
  check("image no alt -> ![x.png](x.png)", out:find("![x.png](x.png)", 1, true) ~= nil)
end

-- Horizontal rule
do
  local doc = A.document({
    A.paragraph({ A.text("above") }),
    A.rule(),
    A.paragraph({ A.text("below") }),
  })
  local out = to_md.render(doc)
  check("rule -> ---", out:find("\n---\n", 1, true) ~= nil, "got: " .. out)
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
  local out = to_md.render(doc)
  check(
    "footnote def -> [^1]: body",
    out:find("[^1]: the footnote body", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Directive (dropped)
do
  local doc = A.document({
    A.directive("TITLE", "My Doc"),
    A.directive("AUTHOR", "Jane"),
    A.paragraph({ A.text("body") }),
  })
  local out = to_md.render(doc)
  check("directive: TITLE dropped", out:find("My Doc", 1, true) == nil, "got: " .. out)
  check("directive: AUTHOR dropped", out:find("Jane", 1, true) == nil)
  check("paragraph still rendered", out:find("body", 1, true) ~= nil)
end

-- Citation rendering (via organ.cite.replace_in)
-- This test loads organ.cite and asserts that to_md routes the inline
-- output through it. Specific citation grammars are organ.cite's
-- responsibility; here we just verify the pass runs.
do
  local cite = require("organ.cite")
  -- Confirm the cite module exposes replace_in (sanity check).
  if type(cite.replace_in) == "function" then
    local doc = A.document({
      A.paragraph({
        A.text("See [cite:@doe2020] for context."),
      }),
    })
    local out = to_md.render(doc)
    -- The simplest assertion: the `[cite:@doe2020]` literal source does
    -- NOT survive into the output, because organ.cite.replace_in would
    -- replace it. The exact replacement form is cite-module-internal;
    -- we just verify the substitution happened.
    check(
      "citation marker replaced by organ.cite",
      out:find("[cite:@doe2020]", 1, true) == nil,
      "got: " .. out
    )
  else
    print("SKIP  citation pass test (organ.cite.replace_in not available)")
  end
end

-- Inline kinds without a markdown form take the HTML form (ox-md
-- derives from ox-html); entities use their HTML names.
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
  local out = to_md.render(doc)
  check("md subscript -> <sub>", out:find("H<sub>2</sub>O", 1, true) ~= nil, "got: " .. out)
  check("md superscript -> <sup>", out:find("x<sup>2</sup>", 1, true) ~= nil)
  check("md entity -> html entity", out:find("&copy; &alpha;", 1, true) ~= nil)
  check("md cookie -> <code>", out:find("<code>[2/3]</code> <code>[50%]</code>", 1, true) ~= nil)
  check(
    "md timestamp -> timestamp spans",
    out:find(
      '<span class="timestamp-wrapper"><span class="timestamp">&lt;2026-09-10 Thu&gt;</span></span>',
      1,
      true
    ) ~= nil
  )
  check("md target -> anchor", out:find('<a id="anchor"></a>', 1, true) ~= nil)
  check("md macro kept as text", out:find("{{{title}}}", 1, true) ~= nil)
  check("md unknown entity kept as text", out:find("\\nosuchentity", 1, true) ~= nil)
end

-- Table without an org separator still gets the GFM delimiter row.
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "l", "r", "c" },
      rows = {
        { sep = false, cells = { { A.text("a") }, { A.text("b") }, { A.text("c") } } },
        { sep = false, cells = { { A.text("1") }, { A.text("2") }, { A.text("3") } } },
        { sep = false, cells = { { A.text("4") }, { A.text("5") }, { A.text("6") } } },
        { sep = true, cells = {} },
        { sep = false, cells = { { A.text("7") }, { A.text("8") }, { A.text("9") } } },
      },
    },
  })
  local out = to_md.render(doc)
  check(
    "delimiter follows the first row",
    out:find("| a | b | c |\n| ---: | ---: | :---: |\n| 1 | 2 | 3 |", 1, true) ~= nil,
    "got: " .. out
  )
  local n = 0
  for line in out:gmatch("[^\n]+") do
    if line:match("^| [:%-]") then
      n = n + 1
    end
  end
  check("exactly one delimiter row", n == 1, "got: " .. out)
  check("rows after the org separator kept", out:find("| 7 | 8 | 9 |", 1, true) ~= nil)
end

-- Plain text escapes markdown-significant characters (org-md-plain-text).
do
  local doc = A.document({
    A.paragraph({
      A.text("2*3*4 snake_case `tick` back\\slash\n# not a heading ![not an image "),
      A.emphasis("verbatim", { A.text("a_b*c") }),
      A.emphasis("code", { A.text("d_e") }),
    }),
    A.paragraph({ A.text("# starts with hash") }),
  })
  local out = to_md.render(doc)
  check("* escaped", out:find("2\\*3\\*4", 1, true) ~= nil, "got: " .. out)
  check("_ escaped", out:find("snake\\_case", 1, true) ~= nil)
  check("` escaped", out:find("\\`tick\\`", 1, true) ~= nil)
  check("\\ escaped", out:find("back\\\\slash", 1, true) ~= nil)
  check("line-leading # escaped", out:find("\n\\# not a heading", 1, true) ~= nil)
  check("![ escaped", out:find("\\![not an image", 1, true) ~= nil)
  check("verbatim content not escaped", out:find("`a_b*c`", 1, true) ~= nil)
  check("code content not escaped", out:find("`d_e`", 1, true) ~= nil)
  check("paragraph-leading # escaped", out:find("\n\\# starts with hash", 1, true) ~= nil)
end

-- List items: nested content indents to the parent's content column,
-- continuation blocks are separated by a blank line, and every block
-- kind inside an item is rendered.
do
  local doc = A.document({
    A.list(true, {
      A.list_item({
        content = {
          A.paragraph({ A.text("alpha") }),
          A.list(false, {
            A.list_item({ content = { A.paragraph({ A.text("nested") }) } }),
          }),
        },
      }),
      A.list_item({ content = { A.paragraph({ A.text("beta") }) } }),
    }),
  })
  local out = to_md.render(doc)
  check(
    "sublist under an ordered item indents 3",
    out:find("1. alpha\n   - nested\n2. beta", 1, true) ~= nil,
    "got: " .. vim.inspect(out)
  )

  local doc2 = A.document({
    A.list(false, {
      A.list_item({
        content = {
          A.paragraph({ A.text("first para") }),
          A.paragraph({ A.text("second para") }),
        },
      }),
      A.list_item({
        content = {
          A.paragraph({ A.text("intro") }),
          A.code_block("lua", "print(1)"),
          A.block("quote", { content = { A.paragraph({ A.text("quoted") }) } }),
        },
      }),
    }),
  })
  local out2 = to_md.render(doc2)
  check(
    "continuation paragraph after a blank line at the content column",
    out2:find("- first para\n\n  second para\n", 1, true) ~= nil,
    "got: " .. vim.inspect(out2)
  )
  check(
    "code block inside an item",
    out2:find("- intro\n\n  ```lua\n  print(1)\n  ```\n", 1, true) ~= nil,
    "got: " .. vim.inspect(out2)
  )
  check(
    "quote block inside an item",
    out2:find("\n  > quoted\n", 1, true) ~= nil,
    "got: " .. vim.inspect(out2)
  )
end

-- Footnotes are numbered by first reference; inline footnotes get a
-- synthesised definition; definitions collect at the end.
do
  local doc = A.document({
    A.paragraph({
      A.text("claim"),
      A.footnote_ref("note"),
      A.text(" and"),
      A.footnote_ref(nil, { A.text("inline body") }),
      A.text(" again"),
      A.footnote_ref("note"),
      A.text("."),
    }),
    A.footnote_definition("note", { A.paragraph({ A.text("The definition.") }) }),
    A.paragraph({ A.text("after") }),
  })
  local out = to_md.render(doc)
  check(
    "refs numbered by first reference",
    out:find("claim[^1] and[^2] again[^1].", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "definitions at the end in number order",
    out:find("after\n\n[^1]: The definition.\n\n[^2]: inline body\n", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Internal and file links resolve to markdown anchors / .md paths.
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Target heading") } }),
    A.headline({ level = 1, title = { A.text("Custom") }, properties = { CUSTOM_ID = "custom" } }),
    A.headline({ level = 1, title = { A.text("By uuid") }, properties = { ID = "abc-123" } }),
    A.headline({ level = 1, title = { A.text("Unreferenced") } }),
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
  local out = to_md.render(doc)
  check("file:x.org -> x.md", out:find("[Notes](notes.md)", 1, true) ~= nil, "got: " .. out)
  check("*Title -> #anchor", out:find("[internal](#target-heading)", 1, true) ~= nil)
  check("#custom -> #custom", out:find("[by id](#custom)", 1, true) ~= nil)
  check("id: -> headline anchor", out:find("[by uuid](#by-uuid)", 1, true) ~= nil)
  check("target -> #name", out:find("[to target](#anchor)", 1, true) ~= nil)
  check(
    "no description -> headline title",
    out:find("[Target heading](#target-heading)", 1, true) ~= nil
  )
  check("unresolved fuzzy -> description text", out:find(" gone ", 1, true) ~= nil)
  check("external untouched", out:find("[q](https://x.y/a?b=1&c=2)", 1, true) ~= nil)
  check(
    "referred headline gets an anchor line",
    out:find('<a id="target-heading"></a>\n\n# Target heading', 1, true) ~= nil,
    "got: " .. out
  )
  check("unreferenced headline has no anchor", out:find('id="unreferenced"', 1, true) == nil)
end

-- Fixed-width lines (`: text`) -- every short babel result is one.
do
  local doc = A.document({ { kind = "fixed_width", body = "42\nnext" } })
  local out = to_md.render(doc)
  check(
    "fixed_width -> indented block",
    out:find("    42\n    next", 1, true) ~= nil,
    "got: " .. out
  )
end

-- LaTeX environments pass through raw, escaped under tex:verbatim.
do
  local body = "\\begin{equation}\nx = 1\n\\end{equation}"
  local doc = A.document({ { kind = "latex_environment", name = "equation", body = body } })
  check(
    "latex_environment passes through raw",
    to_md.render(doc):find(body, 1, true) ~= nil,
    "got: " .. to_md.render(doc)
  )
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_latex = false,
  })
  check("tex:nil drops it", to_md.render(doc):find("equation", 1, true) == nil)
end

-- Greater blocks: center, custom, and backend-gated export blocks.
do
  local doc = A.document({
    A.block("center", { content = { A.paragraph({ A.text("mid") }) } }),
    A.block("export", { backend = "html", body = "<b>raw</b>" }),
    A.block("export", { backend = "latex", body = "\\raw{}" }),
  })
  local out = to_md.render(doc)
  check(
    "center block -> div with markdown inside",
    out:find('<div class="org-center">\n\nmid\n\n</div>', 1, true) ~= nil,
    "got: " .. out
  )
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
  })
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_priority = true,
    with_toc = false,
  })
  local out = to_md.render(doc)
  check(
    "heading carries todo, priority and tags",
    out:find("# TODO [#A] Task one     :work:urgent:", 1, true) ~= nil,
    "got: " .. out
  )
  doc.options.with_todo_keywords = false
  doc.options.with_priority = false
  doc.options.with_tags = false
  check("options switch each part off", to_md.render(doc):find("# Task one", 1, true) ~= nil)
end

-- Description lists keep their terms.
do
  local doc = A.document({
    A.list(false, {
      A.list_item({ tag = { A.text("term") }, content = { A.paragraph({ A.text("definition") }) } }),
    }),
  })
  check(
    "description term -> bold lead-in",
    to_md.render(doc):find("- **term:** definition", 1, true) ~= nil,
    "got: " .. to_md.render(doc)
  )
end

-- Verse keeps inline markup instead of becoming a code fence.
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
  check(
    "verse keeps markup and indentation",
    to_md.render(doc):find(
      '<p class="verse">\nline one **b**<br />\n&#xa0;&#xa0;&#xa0;indented line<br />\n</p>',
      1,
      true
    ) ~= nil,
    "got: " .. to_md.render(doc)
  )
end

-- Captions survive on tables, code blocks and images.
do
  local doc = A.document({
    A.code_block("lua", "print(1)"),
    { kind = "image", target = "./img.png" },
  })
  doc.children[1].affiliated = { { name = "CAPTION", value = "Code caption" } }
  doc.children[2].affiliated = { { name = "CAPTION", value = "Pic caption" } }
  local out = to_md.render(doc)
  check("src block caption", out:find("*Code caption*", 1, true) ~= nil, "got: " .. out)
  check(
    "image caption becomes the title",
    out:find('![./img.png](./img.png "Pic caption")', 1, true) ~= nil
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
    A.headline({ level = 1, title = { A.text("Two") } }),
  })
  local out = to_md.render(doc)
  check("toc heading", out:find("# Table of Contents", 1, true) ~= nil, "got: " .. out)
  check("toc entry", out:find("1.  [One](#one)", 1, true) ~= nil)
  check("toc nests", out:find("    1.  [Deep](#deep)", 1, true) ~= nil)
  check("toc numbers siblings", out:find("2.  [Two](#two)", 1, true) ~= nil)

  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_toc = false,
  })
  check("toc:nil suppresses it", to_md.render(doc):find("Table of Contents", 1, true) == nil)
end

-- Alignment cookies are metadata, not a data row.
do
  local doc = A.document({
    {
      kind = "table",
      alignments = { "r", "l", "c" },
      rows = {
        { cells = { { A.text("<r>") }, { A.text("<l>") }, { A.text("<c>") } }, sep = false },
        { cells = { { A.text("x") }, { A.text("a") }, { A.text("q") } }, sep = false },
      },
    },
  })
  local out = to_md.render(doc)
  check("cookie row is not rendered", out:find("<r>", 1, true) == nil, "got: " .. out)
  check("cookies drive the delimiter row", out:find("| ---: | --- | :---: |", 1, true) ~= nil)
end

-- Entities keep working with the `{}` terminator.
do
  local doc = A.document({ A.paragraph({ A.entity("alpha{}"), A.text("text") }) })
  check("\\alpha{} is the alpha entity", to_md.render(doc):find("&alpha;text", 1, true) ~= nil)
end

-- Special strings, smart quotes and preserved line breaks.
do
  local doc = A.document({ A.paragraph({ A.text('He said "hi" -- a test...\nline two') }) })
  check(
    "special strings on by default",
    to_md.render(doc):find("&#x2013; a test&#x2026;", 1, true) ~= nil,
    "got: " .. to_md.render(doc)
  )
  doc.options = vim.tbl_extend("force", require("organ.export.options").defaults(), {
    with_smart_quotes = true,
    preserve_breaks = true,
  })
  local rich = to_md.render(doc)
  check("smart quotes", rich:find("&ldquo;hi&rdquo;", 1, true) ~= nil, "got: " .. rich)
  check("preserved break", rich:find("&#x2026;  \nline two", 1, true) ~= nil, "got: " .. rich)
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
  local out = to_md.render(doc)
  check("H:2 keeps level 2 a heading", out:find("## Sub", 1, true) ~= nil, "got: " .. out)
  check("H:2 emits no ### heading", out:find("### ", 1, true) == nil, "got: " .. out)
  check("H:2 demotes level 3 to a list item", out:find("- Deep\n", 1, true) ~= nil, "got: " .. out)
  check("H:2 indents the demoted body", out:find("\n  body\n", 1, true) ~= nil, "got: " .. out)
  check("H:2 indents the level 4 item", out:find("\n  - Deeper", 1, true) ~= nil, "got: " .. out)
  check(
    "sibling demoted headline is a sibling item",
    out:find("\n- Deep B", 1, true) ~= nil,
    "got: " .. out
  )

  local numbered = tree()
  numbered.options = opts({ with_section_numbers = true })
  check(
    "num:t demotes into an ordered list",
    to_md.render(numbered):find("1. Deep", 1, true) ~= nil
  )

  local capped = tree()
  capped.options = opts({ with_section_numbers = 2 })
  check(
    "num:2 leaves the demoted list unordered",
    to_md.render(capped):find("- Deep\n", 1, true) ~= nil
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

  local out = to_md.render(from_org.from_lines(src))
  check(
    "#+TOC: headlines builds the document TOC under toc:nil",
    out:find("# Table of Contents", 1, true) ~= nil and out:find("[One](#one)", 1, true) ~= nil,
    "got: " .. out
  )
  check("#+TOC: headlines 2 stops at level 2", out:find("(#three)", 1, true) == nil, "got: " .. out)
  check(
    "#+TOC: ... local is the bare list of the enclosing subtree",
    out:find("# Four\n\n1.  [Five](#five)", 1, true) ~= nil,
    "got: " .. out
  )
  check(
    "ox-md has no list of tables or listings",
    out:find("List of Tables", 1, true) == nil and out:find("List of Listings", 1, true) == nil,
    "got: " .. out
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_md_test: PASS")
os.exit(0)
