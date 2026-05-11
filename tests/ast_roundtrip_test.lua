-- AST round trip: org text -> from_org -> AST -> to_org -> org text.
-- The output won't be byte-for-byte identical to the input (whitespace
-- normalization, comment trimming), but it must parse to the SAME AST
-- on a second pass.
--
-- Phase 1a node coverage: headlines, paragraphs, lists, code blocks,
-- basic emphasis + links.  Other kinds are added as the per-format
-- exporters that need them are migrated.
--
-- Run via: nvim --headless -l tests/ast_roundtrip_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local ast = require("organ.ast")
local from_org = require("organ.ast.from_org")
local to_org = require("organ.ast.to_org")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function lines_of(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

local INPUT = {
  "* TODO First heading",
  "Some paragraph with *bold* and /italic/ text.",
  "And a [[https://example.com][link]] in here.",
  "",
  "** Subheading",
  "- one",
  "- two",
  "- [ ] three",
  "",
  "#+begin_src python",
  "def hello():",
  "    print('hi')",
  "#+end_src",
  "",
  "* DONE [#A] Second heading :work:urgent:",
  "Paragraph with =verbatim= and ~code~.",
}

-- First pass: build AST and validate shape.
local doc = from_org.from_lines(INPUT)
local ok, err = ast.validate(doc)
check("AST is valid after from_lines", ok, err)
check("document has children", #doc.children > 0, "got " .. #doc.children)

-- First headline.
local h1 = doc.children[1]
check(
  "first child is a TODO First heading",
  h1.kind == "headline" and h1.level == 1 and h1.todo == "TODO",
  ("kind=%s level=%s todo=%s"):format(h1.kind, tostring(h1.level), tostring(h1.todo))
)

-- Second pass: render back to org, parse again, AST should match.
local rendered = to_org.render(doc)
local doc2 = from_org.from_lines(lines_of(rendered))

-- Both ASTs should have the same number of top-level children.
check(
  "round-trip preserves top-level children count",
  #doc2.children == #doc.children,
  ("first=%d second=%d"):format(#doc.children, #doc2.children)
)

-- Specific checks: TODO + tags + priority survive.
local h2_first = doc2.children[1]
check(
  "round-trip preserves TODO keyword",
  h2_first.todo == "TODO",
  "got " .. tostring(h2_first.todo)
)

-- Find the second top-level headline to verify priority + tags.
local h_second
for _, c in ipairs(doc2.children) do
  if c.kind == "headline" and c.level == 1 and c.todo == "DONE" then
    h_second = c
    break
  end
end
check("found DONE Second heading on round-trip", h_second ~= nil)
if h_second then
  check(
    "round-trip preserves priority",
    h_second.priority == "A",
    "got " .. tostring(h_second.priority)
  )
  check(
    "round-trip preserves tags",
    h_second.tags
      and #h_second.tags == 2
      and h_second.tags[1] == "work"
      and h_second.tags[2] == "urgent",
    "got " .. vim.inspect(h_second.tags)
  )
end

-- Code block survives.
local found_code = false
local function find_code(n)
  if n.kind == "code_block" and n.language == "python" then
    found_code = true
  end
  for _, slot in ipairs({ "children", "content", "items" }) do
    if n[slot] then
      for _, c in ipairs(n[slot]) do
        find_code(c)
      end
    end
  end
end
find_code(doc2)
check("round-trip preserves a python code block", found_code)

-- ---------- directive (#+TITLE, #+AUTHOR, #+DATE, other) ----------
do
  local INPUT = {
    "#+TITLE: My Document",
    "#+AUTHOR: Jane Doe",
    "#+DATE: 2026-05-11",
    "#+OPTIONS: toc:nil",
    "",
    "* Heading",
    "Some text.",
  }
  local doc = from_org.from_lines(INPUT)

  local seen = {}
  for _, c in ipairs(doc.children) do
    if c.kind == "directive" then
      seen[c.name] = c.value
    end
  end
  check(
    "directive: TITLE captured",
    seen.TITLE == "My Document",
    "got " .. tostring(seen.TITLE)
  )
  check(
    "directive: AUTHOR captured",
    seen.AUTHOR == "Jane Doe",
    "got " .. tostring(seen.AUTHOR)
  )
  check(
    "directive: DATE captured",
    seen.DATE == "2026-05-11",
    "got " .. tostring(seen.DATE)
  )
  check(
    "directive: OPTIONS captured (lowercase / unknown still preserved)",
    seen.OPTIONS == "toc:nil",
    "got " .. tostring(seen.OPTIONS)
  )

  -- Round-trip: render then parse again, directives must survive.
  local rendered = to_org.render(doc)
  local doc2 = from_org.from_lines(lines_of(rendered))
  local seen2 = {}
  for _, c in ipairs(doc2.children) do
    if c.kind == "directive" then
      seen2[c.name] = c.value
    end
  end
  check(
    "directive: TITLE survives round-trip",
    seen2.TITLE == "My Document",
    "got " .. tostring(seen2.TITLE)
  )
end

if fails > 0 then
  print()
  print("--- rendered output ---")
  print(rendered)
  print("---")
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_roundtrip_test: PASS")
os.exit(0)
