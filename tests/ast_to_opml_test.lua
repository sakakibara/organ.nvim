-- Unit tests for organ.ast.to_opml.
-- Run via: nvim --headless -l tests/ast_to_opml_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local A = require("organ.ast")
local to_opml = require("organ.ast.to_opml")

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
  local out = to_opml.render(A.document({}))
  check(
    "empty doc has xml preamble",
    out:find('<?xml version="1.0"', 1, true) ~= nil,
    "got: " .. out
  )
  check("empty doc has opml wrapper", out:find('<opml version="2.0">', 1, true) ~= nil)
  check("empty doc has fallback title", out:find("<title>Org outline</title>", 1, true) ~= nil)
  check(
    "empty doc has empty body",
    out:find("<body>", 1, true) ~= nil and out:find("</body>", 1, true) ~= nil
  )
end

-- Title from #+TITLE: directive
do
  local doc = A.document({
    A.directive("TITLE", "My Outline"),
    A.headline({ level = 1, title = { A.text("Top") } }),
  })
  local out = to_opml.render(doc)
  check(
    "title from directive",
    out:find("<title>My Outline</title>", 1, true) ~= nil,
    "got: " .. out
  )
end

-- Nested headlines + _note
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = { A.text("Top") },
      children = {
        A.paragraph({ A.text("first body line") }),
        A.headline({
          level = 2,
          title = { A.text("Sub") },
          children = {
            A.headline({ level = 3, title = { A.text("Deep") } }),
          },
        }),
      },
    }),
    A.headline({
      level = 1,
      title = { A.text("Sibling") },
      children = { A.paragraph({ A.text("another note") }) },
    }),
  })
  local out = to_opml.render(doc)
  check("Top outline element", out:find('<outline text="Top"', 1, true) ~= nil, "got: " .. out)
  check("Top _note from first paragraph", out:find('_note="first body line"', 1, true) ~= nil)
  check("Sub outline element", out:find('<outline text="Sub"', 1, true) ~= nil)
  check("Deep outline element", out:find('<outline text="Deep"', 1, true) ~= nil)
  check("Sibling outline element", out:find('<outline text="Sibling"', 1, true) ~= nil)
  check("Sibling _note", out:find('_note="another note"', 1, true) ~= nil)

  local n_close = 0
  for _ in out:gmatch("</outline>") do
    n_close = n_close + 1
  end
  check("4 closing outline tags", n_close == 4, "got " .. n_close)
end

-- TODO + tags stripped from title attribute
-- In the AST, todo / tags are SEPARATE fields on the headline node; they
-- don't pollute node.title.  This verifies that property end-to-end.
do
  local doc = A.document({
    A.headline({
      level = 1,
      todo = "TODO",
      title = { A.text("Buy milk") },
      tags = { "shopping" },
    }),
  })
  local out = to_opml.render(doc)
  check(
    "TODO keyword absent from text attribute",
    out:find('text="TODO Buy milk"', 1, true) == nil,
    "got: " .. out
  )
  check("tags absent from text attribute", out:find(":shopping:", 1, true) == nil, "got: " .. out)
  check(
    "title preserved without TODO/tags",
    out:find('text="Buy milk"', 1, true) ~= nil,
    "got: " .. out
  )
end

-- XML special chars escaped
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text('A & B <test> "q"') } }),
  })
  local out = to_opml.render(doc)
  check("& escaped to &amp;", out:find("A &amp; B", 1, true) ~= nil, "got: " .. out)
  check("< escaped to &lt;", out:find("&lt;test&gt;", 1, true) ~= nil)
  check('" escaped to &quot;', out:find("&quot;q&quot;", 1, true) ~= nil)
end

-- _note source: emphasis stripped
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = { A.text("H") },
      children = {
        A.paragraph({
          A.text("note with "),
          A.emphasis("bold", { A.text("bold") }),
          A.text(" text"),
        }),
      },
    }),
  })
  local out = to_opml.render(doc)
  check(
    "_note has plain text only (emphasis stripped)",
    out:find('_note="note with bold text"', 1, true) ~= nil,
    "got: " .. out
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_opml_test: PASS")
os.exit(0)
