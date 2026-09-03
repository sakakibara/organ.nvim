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
    "inline image with alt -> ![fig](fig.png)",
    out:find("![fig](fig.png)", 1, true) ~= nil,
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
  check("partial checkbox -> [ ] (GFM has no partial)", out:find("- [ ] c", 1, true) ~= nil)
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
    "example -> fenced code (no language)",
    out:find("```\nraw text\nline 2\n```", 1, true) ~= nil,
    "got: " .. out
  )
end

do
  local doc = A.document({
    A.block("verse", { body = "verse 1\nverse 2" }),
  })
  local out = to_md.render(doc)
  check(
    "verse -> fenced code (no language)",
    out:find("```\nverse 1\nverse 2\n```", 1, true) ~= nil
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
  check("divider row", out:find("| --- | --- |", 1, true) ~= nil)
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
    "block image -> ![diagram](fig.png)",
    out:find("![diagram](fig.png)", 1, true) ~= nil,
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
    out:find("| a | b | c |\n| --- | ---: | :---: |\n| 1 | 2 | 3 |", 1, true) ~= nil,
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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_md_test: PASS")
os.exit(0)
