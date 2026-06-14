-- AST round trip: org text -> from_org -> AST -> to_org -> org text.
-- The output won't be byte-for-byte identical to the input (whitespace
-- normalization, comment trimming), but it must parse to the SAME AST
-- on a second pass.
--
-- Covers headlines, paragraphs, lists, code blocks, emphasis, links,
-- directives, horizontal rules, blocks (quote/verse/example/export),
-- tables, free-standing images, inline + display math, and footnotes
-- (inline ref + block definition).
--
-- Run via: nvim --headless -l tests/ast_roundtrip_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  -- Pin tag right edge at 77 so the headline-alignment assertions
  -- below stay independent of textwidth (production default is
  -- "textwidth", which would resolve to whatever the headless
  -- buffer's textwidth happens to be).
  format = { headline = { tags_column = -77 } },
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
  check("directive: TITLE captured", seen.TITLE == "My Document", "got " .. tostring(seen.TITLE))
  check("directive: AUTHOR captured", seen.AUTHOR == "Jane Doe", "got " .. tostring(seen.AUTHOR))
  check("directive: DATE captured", seen.DATE == "2026-05-11", "got " .. tostring(seen.DATE))
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

-- ---------- rule (horizontal rule) ----------
do
  local INPUT = {
    "Above the line.",
    "",
    "-----",
    "",
    "Below the line.",
  }
  local doc = from_org.from_lines(INPUT)

  local has_rule = false
  for _, c in ipairs(doc.children) do
    if c.kind == "rule" then
      has_rule = true
    end
  end
  check("rule: emitted from -----", has_rule)

  local rendered = to_org.render(doc)
  local doc2 = from_org.from_lines(lines_of(rendered))
  local has_rule2 = false
  for _, c in ipairs(doc2.children) do
    if c.kind == "rule" then
      has_rule2 = true
    end
  end
  check("rule: survives round-trip", has_rule2)
end

-- ---------- block (quote / verse / example / export) ----------
do
  local INPUT = {
    "#+begin_quote",
    "A quote with *emphasis*.",
    "#+end_quote",
    "",
    "#+begin_example",
    "raw monospace; *no* emphasis parsing here.",
    "#+end_example",
    "",
    "#+begin_verse",
    "Line one.",
    "Line two.",
    "#+end_verse",
    "",
    "#+begin_export html",
    "<p>passthrough</p>",
    "#+end_export",
  }
  local doc = from_org.from_lines(INPUT)

  local seen = {}
  for _, c in ipairs(doc.children) do
    if c.kind == "block" then
      seen[c.style] = c
    end
  end
  check("block: quote present", seen.quote ~= nil)
  check("block: example present", seen.example ~= nil)
  check("block: verse present", seen.verse ~= nil)
  check("block: export present", seen.export ~= nil)

  check(
    "block: example has body string (verbatim)",
    seen.example and type(seen.example.body) == "string",
    seen.example and ("type=" .. type(seen.example.body)) or "missing"
  )
  check(
    "block: quote has content list (parsed)",
    seen.quote and type(seen.quote.content) == "table",
    seen.quote and ("type=" .. type(seen.quote.content)) or "missing"
  )

  local rendered = to_org.render(doc)
  local doc2 = from_org.from_lines(lines_of(rendered))
  local seen2 = {}
  for _, c in ipairs(doc2.children) do
    if c.kind == "block" then
      seen2[c.style] = c
    end
  end
  check("block: quote survives round-trip", seen2.quote ~= nil)
  check("block: example survives round-trip", seen2.example ~= nil)
  check("block: verse survives round-trip", seen2.verse ~= nil)
  check("block: export survives round-trip", seen2.export ~= nil)
end

-- ---------- table ----------
do
  local INPUT = {
    "| name  | age |",
    "|-------+-----|",
    "| Alice |  30 |",
    "| Bob   |  25 |",
  }
  local doc = from_org.from_lines(INPUT)

  local tbl
  for _, c in ipairs(doc.children) do
    if c.kind == "table" then
      tbl = c
    end
  end
  check("table: emitted", tbl ~= nil)
  if tbl then
    check(
      "table: 4 rows (header + separator + 2 data)",
      #tbl.rows == 4,
      "got " .. tostring(#tbl.rows)
    )
    check(
      "table: header row first cell text is 'name'",
      tbl.rows[1].cells[1][1] and tbl.rows[1].cells[1][1].text == "name"
    )
    check(
      "table: separator row marked",
      tbl.rows[2].sep == true,
      "got " .. tostring(tbl.rows[2] and tbl.rows[2].sep)
    )
    check(
      "table: alignments defaults to 'l' per column",
      tbl.alignments and #tbl.alignments == 2 and tbl.alignments[1] == "l",
      "got " .. vim.inspect(tbl.alignments)
    )
  end

  local rendered = to_org.render(doc)
  local doc2 = from_org.from_lines(lines_of(rendered))
  local tbl2
  for _, c in ipairs(doc2.children) do
    if c.kind == "table" then
      tbl2 = c
    end
  end
  check("table: survives round-trip", tbl2 ~= nil and #tbl2.rows == 4)
end

-- ---------- image (free-standing block) ----------
do
  local INPUT = {
    "Some text before.",
    "",
    "[[./figures/diagram.png]]",
    "",
    "Some text after.",
  }
  local doc = from_org.from_lines(INPUT)

  local img
  for _, c in ipairs(doc.children) do
    if c.kind == "image" then
      img = c
    end
  end
  check("image: free-standing emitted as block", img ~= nil)
  if img then
    check(
      "image: target preserved",
      img.target == "./figures/diagram.png",
      "got " .. tostring(img.target)
    )
  end

  -- Inline image inside a paragraph should still be an inline `image`
  -- under a `paragraph`, NOT a free-standing block.
  local INPUT2 = {
    "See [[./figures/diagram.png]] for details.",
  }
  local doc_inline = from_org.from_lines(INPUT2)
  local first = doc_inline.children[1]
  check("image: inline-with-text stays inside paragraph", first and first.kind == "paragraph")

  local rendered = to_org.render(doc)
  local doc2 = from_org.from_lines(lines_of(rendered))
  local has_img = false
  for _, c in ipairs(doc2.children) do
    if c.kind == "image" then
      has_img = true
    end
  end
  check("image: survives round-trip", has_img)
end

-- ---------- math (inline + display) ----------
do
  local INPUT = {
    "Inline math: $x^2 + y^2 = z^2$ here.",
    "And paren form: \\(a + b\\) here.",
    "",
    "Display math:",
    "$$\\int_0^1 f(x)\\,dx$$",
    "",
    "And bracket form:",
    "\\[\\sum_{i=0}^n i\\]",
  }
  local doc = from_org.from_lines(INPUT)

  local maths = {}
  local function collect(n)
    if n.kind == "math" then
      maths[#maths + 1] = n
    end
    for _, slot in ipairs({ "children", "content", "inline", "title" }) do
      if n[slot] then
        for _, c in ipairs(n[slot]) do
          collect(c)
        end
      end
    end
  end
  collect(doc)
  check("math: 4 nodes collected", #maths == 4, "got " .. #maths)
  if #maths >= 4 then
    check("math: first is inline ($)", maths[1].display == false)
    check("math: second is inline (\\(\\))", maths[2].display == false)
    check("math: third is display ($$)", maths[3].display == true)
    check("math: fourth is display (\\[\\])", maths[4].display == true)
    check(
      "math: first body preserved",
      maths[1].body == "x^2 + y^2 = z^2",
      "got " .. tostring(maths[1].body)
    )
  end

  local rendered = to_org.render(doc)
  local doc2 = from_org.from_lines(lines_of(rendered))
  local maths2 = {}
  local function collect2(n)
    if n.kind == "math" then
      maths2[#maths2 + 1] = n
    end
    for _, slot in ipairs({ "children", "content", "inline", "title" }) do
      if n[slot] then
        for _, c in ipairs(n[slot]) do
          collect2(c)
        end
      end
    end
  end
  collect2(doc2)
  check("math: 4 nodes survive round-trip", #maths2 == 4, "got " .. #maths2)
end

-- ---------- footnotes (inline ref + block definition) ----------
do
  local INPUT = {
    "Some claim[fn:1] in the text.",
    "Another sentence[fn:2] follows.",
    "",
    "[fn:1] First footnote body.",
    "[fn:2] Second footnote, with *emphasis*.",
  }
  local doc = from_org.from_lines(INPUT)

  -- Collect inline footnote_refs.
  local refs = {}
  local function collect_refs(n)
    if n.kind == "footnote_ref" then
      refs[#refs + 1] = n
    end
    for _, slot in ipairs({ "children", "content", "inline", "title" }) do
      if n[slot] then
        for _, c in ipairs(n[slot]) do
          collect_refs(c)
        end
      end
    end
  end
  collect_refs(doc)
  check("footnote: 2 inline refs", #refs == 2, "got " .. #refs)
  if #refs >= 2 then
    check("footnote: first ref label", refs[1].label == "1", "got " .. tostring(refs[1].label))
    check("footnote: second ref label", refs[2].label == "2", "got " .. tostring(refs[2].label))
  end

  -- Collect block footnote_definitions.
  local defs = {}
  for _, c in ipairs(doc.children) do
    if c.kind == "footnote_definition" then
      defs[#defs + 1] = c
    end
  end
  check("footnote: 2 block definitions", #defs == 2, "got " .. #defs)
  if #defs >= 2 then
    check("footnote: first def label", defs[1].label == "1", "got " .. tostring(defs[1].label))
    check(
      "footnote: first def content is a list of blocks",
      type(defs[1].content) == "table"
        and defs[1].content[1]
        and defs[1].content[1].kind == "paragraph"
    )
  end

  local rendered = to_org.render(doc)
  local doc2 = from_org.from_lines(lines_of(rendered))
  refs = {}
  collect_refs(doc2)
  check("footnote: 2 refs survive round-trip", #refs == 2, "got " .. #refs)
  local defs2 = 0
  for _, c in ipairs(doc2.children) do
    if c.kind == "footnote_definition" then
      defs2 = defs2 + 1
    end
  end
  check("footnote: 2 definitions survive round-trip", defs2 == 2, "got " .. defs2)
end

-- ---------- headline tag-block alignment (`config.format.headline.tags_column`) ----------
-- The to_org emitter right-aligns tags to `tags_column` (default 77),
-- using the same `format.align_tag_block` helper as `:Org format` and
-- `tag_writer`.  Verify the rendered headline line has correct padding.
do
  local INPUT = { "* DONE [#A] Second heading :work:urgent:" }
  local doc = from_org.from_lines(INPUT)
  local rendered = to_org.render(doc)
  -- Find the headline line in the output.
  local headline_line
  for line in (rendered .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%* DONE") then
      headline_line = line
      break
    end
  end
  check("headline tag align: line emitted", headline_line ~= nil)
  if headline_line then
    local right_edge = vim.fn.strdisplaywidth(headline_line)
    check(
      "headline tag align: right edge at column 77",
      right_edge == 77,
      "got width " .. right_edge .. " line=[" .. headline_line .. "]"
    )
    check(
      "headline tag align: tag block present at end",
      headline_line:sub(-#":work:urgent:") == ":work:urgent:",
      "line=[" .. headline_line .. "]"
    )
    -- Body text is "* DONE [#A] Second heading" -> width 26.  Tag block
    -- ":work:urgent:" -> width 13.  Pad to 77 = 77 - 26 - 13 = 38 spaces.
    local left = "* DONE [#A] Second heading"
    local block = ":work:urgent:"
    local want_pad = 77 - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(block)
    local want_line = left .. string.rep(" ", want_pad) .. block
    check(
      "headline tag align: exact pad width",
      headline_line == want_line,
      "got [" .. headline_line .. "] want [" .. want_line .. "]"
    )
  end
end

-- A headline without tags has no trailing whitespace introduced by the
-- aligner.
do
  local INPUT = { "* Untagged heading" }
  local doc = from_org.from_lines(INPUT)
  local rendered = to_org.render(doc)
  local headline_line
  for line in (rendered .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%* ") then
      headline_line = line
      break
    end
  end
  check(
    "headline no tags: no trailing whitespace",
    headline_line == "* Untagged heading",
    "got [" .. tostring(headline_line) .. "]"
  )
end

-- Long headline (already past tags_column) falls back to one space of pad.
do
  local long_title = string.rep("x", 80)
  local INPUT = { "* " .. long_title .. " :t:" }
  local doc = from_org.from_lines(INPUT)
  local rendered = to_org.render(doc)
  local headline_line
  for line in (rendered .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%* ") then
      headline_line = line
      break
    end
  end
  check(
    "headline overflow: pad clamps to one space",
    headline_line == "* " .. long_title .. " :t:",
    "got [" .. tostring(headline_line) .. "]"
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
