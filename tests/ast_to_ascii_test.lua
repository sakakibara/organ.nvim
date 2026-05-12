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

-- ---- empty document --------------------------------------------------
do
  local out = to_ascii.render(A.document({}))
  check("empty doc renders to single newline", out == "\n", "got: " .. vim.inspect(out))
end

-- ---- headlines (per-level underlines) --------------------------------
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

-- ---- paragraph -------------------------------------------------------
do
  local doc = A.document({
    A.paragraph({ A.text("simple text") }),
  })
  local out = to_ascii.render(doc)
  check("paragraph renders plain", out:find("simple text", 1, true) ~= nil, "got: " .. out)
end

-- ---- inline emphasis stripped ----------------------------------------
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

-- ---- inline link with description ------------------------------------
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

-- ---- bare link (no description) --------------------------------------
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

-- ---- math (rendered as body, no $ delimiters) ------------------------
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
    "math body emitted without delimiters",
    out:find("see x^2 and \\int", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- inline image dropped --------------------------------------------
do
  local doc = A.document({
    A.paragraph({
      A.text("before "),
      { kind = "image", target = "fig.png", alt = "fig" },
      A.text(" after"),
    }),
  })
  local out = to_ascii.render(doc)
  check("inline image dropped", out:find("before  after", 1, true) ~= nil, "got: " .. out)
end

-- ---- footnote_ref dropped --------------------------------------------
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

-- ---- list (unordered, basic) ----------------------------------------
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

-- ---- list (ordered: bullets normalised to "-") -----------------------
do
  local doc = A.document({
    A.list(true, {
      A.list_item({ content = { A.paragraph({ A.text("alpha") }) } }),
      A.list_item({ content = { A.paragraph({ A.text("beta") }) } }),
    }),
  })
  local out = to_ascii.render(doc)
  check(
    "ordered list bullets normalised to -",
    out:find("- alpha", 1, true) ~= nil and out:find("- beta", 1, true) ~= nil,
    "got: " .. out
  )
end

-- ---- list (checkboxes preserved as [X]/[ ]/[-]) ----------------------
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

-- ---- list (nested 2-space indent) ------------------------------------
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

-- ---- code_block: 4-space indent --------------------------------------
do
  local doc = A.document({
    A.code_block("python", "print('hi')"),
  })
  local out = to_ascii.render(doc)
  check("code body indented 4 spaces", out:find("    print('hi')", 1, true) ~= nil, "got: " .. out)
end

-- Multi-line code preserves line breaks, each line indented.
do
  local doc = A.document({
    A.code_block("lua", "local x = 1\nprint(x)"),
  })
  local out = to_ascii.render(doc)
  check(
    "multi-line code: line 1 indented",
    out:find("    local x = 1", 1, true) ~= nil,
    "got: " .. out
  )
  check("multi-line code: line 2 indented", out:find("    print(x)", 1, true) ~= nil)
end

-- ---- block: example -------------------------------------------------
do
  local doc = A.document({
    A.block("example", { body = "raw text\nline 2" }),
  })
  local out = to_ascii.render(doc)
  check(
    "example indented 4 spaces line 1",
    out:find("    raw text", 1, true) ~= nil,
    "got: " .. out
  )
  check("example indented 4 spaces line 2", out:find("    line 2", 1, true) ~= nil)
end

-- ---- block: verse ---------------------------------------------------
do
  local doc = A.document({
    A.block("verse", { body = "v1\nv2" }),
  })
  local out = to_ascii.render(doc)
  check("verse indented like example", out:find("    v1", 1, true) ~= nil, "got: " .. out)
  check("verse line 2 indented", out:find("    v2", 1, true) ~= nil)
end

-- ---- block: quote ---------------------------------------------------
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

-- ---- block: export (dropped) ----------------------------------------
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

-- ---- table (basic) -------------------------------------------------
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

-- ---- table (multi-divider preserves them all) ---------------------
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

-- ---- table (column widths fit widest cell) -----------------------
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

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_ascii_test: PASS")
os.exit(0)
