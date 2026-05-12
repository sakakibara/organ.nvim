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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_md_test: PASS")
os.exit(0)
