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

-- ---- empty document --------------------------------------------------
do
  local doc = A.document({})
  local out = to_md.render(doc)
  check("empty doc renders to a single newline", out == "\n", "got " .. vim.inspect(out))
end

-- ---- headlines (ATX, levels 1-6) -------------------------------------
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

-- ---- paragraph + text inline -----------------------------------------
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

-- ---- inline link -----------------------------------------------------
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

-- ---- inline image (within paragraph) ---------------------------------
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

-- ---- inline footnote_ref ---------------------------------------------
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

-- ---- inline math (inline + display) ----------------------------------
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

-- ---- linebreak -------------------------------------------------------
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

-- ---- list (unordered, basic) ----------------------------------------
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

-- ---- list (ordered, basic) ------------------------------------------
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

-- ---- list (checkboxes) ----------------------------------------------
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
  local out = to_md.render(doc)
  check("outer at column 0", out:find("- outer", 1, true) ~= nil, "got: " .. out)
  check("inner indented 2 spaces", out:find("  - inner", 1, true) ~= nil)
end

-- ---- code_block -----------------------------------------------------
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

-- ---- block: quote --------------------------------------------------
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

-- ---- block: example / verse (body as fenced code) ------------------
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

-- ---- block: export (dropped) ---------------------------------------
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

-- ---- table (basic) -------------------------------------------------
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

-- ---- block-level image ---------------------------------------------
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

-- ---- horizontal rule -----------------------------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("above") }),
    A.rule(),
    A.paragraph({ A.text("below") }),
  })
  local out = to_md.render(doc)
  check("rule -> ---", out:find("\n---\n", 1, true) ~= nil, "got: " .. out)
end

-- ---- footnote_definition -------------------------------------------
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

-- ---- directive (dropped) -------------------------------------------
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

-- ---- citation rendering (via organ.cite.replace_in) -----------------
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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_md_test: PASS")
os.exit(0)
