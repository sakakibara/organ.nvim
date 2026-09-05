-- Pins organ.ast.org_entities: table shape, a representative row from every
-- class the table covers, and the rendering each exporter derives from those
-- rows (including the `\name{}` terminator form).
--
-- Run via: nvim --headless -l tests/org_entities_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local A = require("organ.ast")
local ENT = require("organ.ast.org_entities")
local to_html = require("organ.ast.to_html")
local to_latex = require("organ.ast.to_latex")
local to_ascii = require("organ.ast.to_ascii")
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

-- Shape: every consumer reads latex / math / html / ascii / utf8.
do
  local n, bad = 0, {}
  for name, e in pairs(ENT) do
    n = n + 1
    if
      type(e.latex) ~= "string"
      or e.latex == ""
      or type(e.math) ~= "boolean"
      or type(e.html) ~= "string"
      or e.html == ""
      or type(e.ascii) ~= "string"
      or type(e.utf8) ~= "string"
      or e.utf8 == ""
    then
      bad[#bad + 1] = name
    end
  end
  check("every entry has the five fields", #bad == 0, table.concat(bad, " "))
  check("table covers the org entity set", n > 400, "got " .. n)
end

-- A text-mode LaTeX control word must be terminated, or it eats the space
-- after it.
do
  local bad = {}
  for name, e in pairs(ENT) do
    if not e.math and e.latex:match("^\\%a+$") then
      bad[#bad + 1] = name
    end
  end
  check("text-mode control words are brace-terminated", #bad == 0, table.concat(bad, " "))
end

local ROWS = {
  -- accented latin
  { "Agrave", "\\`{A}", false, "&Agrave;", "A", "À" },
  { "szlig", "\\ss{}", false, "&szlig;", "ss", "ß" },
  { "AA", "\\AA{}", false, "&Aring;", "A", "Å" },
  -- greek
  { "alpha", "\\alpha", true, "&alpha;", "alpha", "α" },
  { "Omega", "\\Omega", true, "&Omega;", "Omega", "Ω" },
  { "Alpha", "A", false, "&Alpha;", "Alpha", "Α" },
  -- math operators and relations
  { "sum", "\\sum", true, "&sum;", "sum", "∑" },
  { "leq", "\\leq", true, "&leq;", "<=", "≤" },
  { "to", "\\to", true, "&rarr;", "->", "→" },
  { "cdot", "\\cdot", true, "&sdot;", ".", "⋅" },
  -- currency
  { "euro", "\\texteuro{}", false, "&euro;", "EUR", "€" },
  { "EUR", "\\texteuro{}", false, "&euro;", "EUR", "€" },
  { "yen", "\\textyen{}", false, "&yen;", "yen", "¥" },
  -- signs
  { "copy", "\\textcopyright{}", false, "&copy;", "(c)", "©" },
  { "S", "\\S{}", false, "&sect;", "section", "§" },
  -- spacing
  { "nbsp", "~", false, "&nbsp;", " ", "\194\160" },
  { "_ ", "\\hspace*{0.5em}", false, "&ensp;", " ", "\226\128\130" },
  {
    "_   ",
    "\\hspace*{1.5em}",
    false,
    "&ensp;&ensp;&ensp;",
    "   ",
    "\226\128\130\226\128\130\226\128\130",
  },
  -- LaTeX operator name: renders as itself everywhere but LaTeX
  { "arccos", "\\arccos", true, "arccos", "arccos", "arccos" },
}

for _, r in ipairs(ROWS) do
  local name, e = r[1], ENT[r[1]]
  if not e then
    check("entity " .. name .. " exists", false)
  else
    check(
      ("%q renders %s / %s / %s / %s"):format(name, r[2], r[4], r[5], r[6]),
      e.latex == r[2] and e.math == r[3] and e.html == r[4] and e.ascii == r[5] and e.utf8 == r[6],
      ("latex=%q math=%s html=%q ascii=%q utf8=%q"):format(
        e.latex,
        tostring(e.math),
        e.html,
        e.ascii,
        e.utf8
      )
    )
  end
end

-- The `\name{}` form names the same entity; the braces only terminate it.
local function doc(name)
  return A.document({ A.paragraph({ A.text("x"), A.entity(name), A.text("y") }) })
end

do
  local out = to_html.render(doc("alpha{}"), { body_only = true })
  check("html: \\alpha{} is the alpha entity", out:find("x&alpha;y", 1, true) ~= nil, out)
end

do
  local out = to_latex.render(doc("alpha{}"), { body_only = true })
  check("latex: \\alpha{} is the alpha entity", out:find("x\\(\\alpha\\)y", 1, true) ~= nil, out)
end

-- Exporters read the columns they are supposed to read.
do
  local out = to_html.render(doc("euro"), { body_only = true })
  check("html uses the html column", out:find("x&euro;y", 1, true) ~= nil, out)
end

do
  local out = to_latex.render(doc("copy"), { body_only = true })
  check(
    "latex uses the latex column verbatim in text mode",
    out:find("x\\textcopyright{}y", 1, true) ~= nil,
    out
  )
end

do
  local out = to_latex.render(doc("sum"), { body_only = true })
  check("latex wraps a math entity in \\( \\)", out:find("x\\(\\sum\\)y", 1, true) ~= nil, out)
end

do
  local out = to_ascii.render(doc("leq"))
  check("ascii uses the ascii column", out:find("x<=y", 1, true) ~= nil, out)
end

do
  local out = to_texinfo.render(doc("Agrave"), { body_only = true })
  check("texinfo falls back to the utf8 column", out:find("xÀy", 1, true) ~= nil, out)
end

do
  local out = to_texinfo.render(doc("_   "), { body_only = true })
  check("texinfo renders a spacing entity as @w{}", out:find("x@w{   }y", 1, true) ~= nil, out)
end

do
  local out = to_ascii.render(doc("_    "))
  check(
    "ascii renders a spacing entity as that many spaces",
    out:find("x    y", 1, true) ~= nil,
    out
  )
end

-- An unknown name still passes through as literal markup.
do
  local out = to_html.render(doc("nosuchentity"), { body_only = true })
  check("unknown name passes through", out:find("\\nosuchentity", 1, true) ~= nil, out)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("org_entities_test: PASS")
os.exit(0)
