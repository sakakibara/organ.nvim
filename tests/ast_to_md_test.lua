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
  check("empty doc renders to a single newline", out == "\n",
    "got " .. vim.inspect(out))
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
  check("level 8 clamps to 6 hashes", out:find("###### Way deep", 1, true) ~= nil,
    "got: " .. out)
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
  check("headline then paragraph: both present",
    out:find("# H", 1, true) ~= nil and out:find("body", 1, true) ~= nil,
    "got: " .. out)
end

-- ---- emphasis (6 styles) ---------------------------------------------
do
  local doc = A.document({
    A.paragraph({
      A.text("a "), A.emphasis("bold", { A.text("B") }),
      A.text(" b "), A.emphasis("italic", { A.text("I") }),
      A.text(" c "), A.emphasis("underline", { A.text("U") }),
      A.text(" d "), A.emphasis("strike", { A.text("S") }),
      A.text(" e "), A.emphasis("verbatim", { A.text("V") }),
      A.text(" f "), A.emphasis("code", { A.text("C") }),
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
  check("nested bold inside italic",
    out:find("*outer **inner***", 1, true) ~= nil,
    "got: " .. out)
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
  check("link with description", out:find("[a link](https://example.com)", 1, true) ~= nil,
    "got: " .. out)
  check("naked link",
    out:find("[https://naked.example.com](https://naked.example.com)", 1, true) ~= nil)
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
  check("inline image with alt -> ![fig](fig.png)",
    out:find("![fig](fig.png)", 1, true) ~= nil,
    "got: " .. out)
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
  check("footnote_ref -> [^1]", out:find("[^1]", 1, true) ~= nil,
    "got: " .. out)
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
  check("display math -> $$...$$",
    out:find("$$\\int_0^1 x dx$$", 1, true) ~= nil,
    "got: " .. out)
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
  check("linebreak emits two-space + newline",
    out:find("first  \nsecond", 1, true) ~= nil,
    "got: " .. vim.inspect(out))
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
  check("unordered list - one / - two",
    out:find("- one", 1, true) ~= nil and out:find("- two", 1, true) ~= nil,
    "got: " .. out)
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
  check("ordered list 1. / 2.",
    out:find("1. alpha", 1, true) ~= nil and out:find("2. beta", 1, true) ~= nil,
    "got: " .. out)
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
  check("partial checkbox -> [ ] (GFM has no partial)",
    out:find("- [ ] c", 1, true) ~= nil)
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
  check("fenced code with language", out:find("```python\nprint('hi')\n```", 1, true) ~= nil,
    "got: " .. out)
end

-- Code block with no language: still fenced.
do
  local doc = A.document({
    A.code_block(nil, "raw"),
  })
  local out = to_md.render(doc)
  check("fenced code no language", out:find("```\nraw\n```", 1, true) ~= nil,
    "got: " .. out)
end

-- Multi-line code preserves body verbatim.
do
  local doc = A.document({
    A.code_block("lua", "local x = 1\nprint(x)"),
  })
  local out = to_md.render(doc)
  check("multi-line code preserves newlines",
    out:find("```lua\nlocal x = 1\nprint(x)\n```", 1, true) ~= nil)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_md_test: PASS")
os.exit(0)
