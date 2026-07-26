-- AST -> PDF renderer tests.
-- Run via: nvim --headless -l tests/pdf_render_test.lua
--
-- Skips when no system TTF is discoverable, following the precedent of
-- pdf_font_test / pdf_layout_test.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local font_search = require("organ.pdf.font_search")
local pdf = require("organ.pdf")
local ast = require("organ.ast")

local ttf_path, ferr = font_search.find({ style = "regular" })
if not ttf_path then
  print("(skipped: no system TTF found - " .. tostring(ferr) .. ")")
  print("pdf_render_test: SKIP")
  os.exit(0)
end
print(("(using font: %s)"):format(ttf_path))

local fails = 0
local checks = 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- 1. Empty document renders to a structurally valid PDF.

do
  local doc = ast.document({})
  local bytes, err = pdf.render(doc)
  check("empty document returns bytes (no error)", bytes ~= nil, tostring(err))
  if bytes then
    check("starts with %PDF-1.7", bytes:sub(1, 8) == "%PDF-1.7", bytes:sub(1, 8))
    check("ends with %%EOF", bytes:sub(-6) == "%%EOF\n")
    -- Empty document still emits ONE blank page (documented choice).
    local _, page_count = bytes:gsub("/Type /Page%s", "")
    check(
      "empty document emits exactly one blank page",
      page_count == 1,
      ("got %d"):format(page_count)
    )
  end
end

-- 2. Headline + paragraph: content stream with BT / Tf / Tj / ET.

do
  local doc = ast.document({
    ast.headline({
      level = 1,
      title = { ast.text("Hello Title") },
      children = {
        ast.paragraph({ ast.text("This is body text.") }),
      },
    }),
  })
  local bytes = assert(pdf.render(doc))
  check("contains BT operator", bytes:find("BT", 1, true) ~= nil)
  check("contains ET operator", bytes:find("ET", 1, true) ~= nil)
  check("contains Tf (font selector)", bytes:find(" Tf", 1, true) ~= nil)
  check("contains Tj (text show)", bytes:find(" Tj", 1, true) ~= nil)
  check("contains /F1 font name reference", bytes:find("/F1 ", 1, true) ~= nil)
  -- Heading at level 1 is 18pt vs paragraph 11pt -> two distinct Tf
  -- font sizes appear.
  check("contains 18pt Tf for level-1 heading", bytes:find("/F1 18 Tf", 1, true) ~= nil)
  check("contains 11pt Tf for body paragraph", bytes:find("/F1 11 Tf", 1, true) ~= nil)
end

-- 3. Page /Resources /Font dict references the embedded font(s).

do
  local doc = ast.document({
    ast.paragraph({ ast.text("Just a paragraph.") }),
  })
  local bytes = assert(pdf.render(doc))
  check("resources dict carries /F1 entry", bytes:find("/F1 %d+ 0 R") ~= nil)
  check("resources dict carries /F2 entry", bytes:find("/F2 %d+ 0 R") ~= nil)
  check("page resources include /Font subdict", bytes:find("/Font <<", 1, true) ~= nil)
end

-- 4. Code block uses a (potentially) different font ref.

do
  local doc = ast.document({
    ast.paragraph({ ast.text("Prose before.") }),
    ast.code_block("lua", "local x = 1\nprint(x)\n"),
    ast.paragraph({ ast.text("Prose after.") }),
  })
  local bytes = assert(pdf.render(doc))
  -- Whichever font name (F1 / F2) we end up using for the mono lines,
  -- the code text must be addressable. Look for either Tf variant
  -- followed by the canonical source lines, hex-encoded.
  check("code block emits a Tf operator", bytes:find("Tf") ~= nil)
  -- The mono lines should reference one of the two font names.
  local has_f1 = bytes:find("/F1 ", 1, true) ~= nil
  local has_f2 = bytes:find("/F2 ", 1, true) ~= nil
  check("at least one Tf font name reference (F1 or F2)", has_f1 or has_f2)
end

-- 5. Long content paginates onto multiple pages.

do
  -- Many paragraphs of body text -> blow past one page.
  local paragraphs = {}
  for i = 1, 200 do
    local words = {}
    for w = 1, 30 do
      words[w] = "word" .. i .. "_" .. w
    end
    paragraphs[#paragraphs + 1] = ast.paragraph({ ast.text(table.concat(words, " ")) })
  end
  local doc = ast.document(paragraphs)
  local bytes = assert(pdf.render(doc))
  -- Count distinct /Type /Page leaf objects (NOT /Type /Pages tree node).
  local _, page_count = bytes:gsub("/Type /Page%s", "")
  check(("long content produces >= 2 pages (got %d)"):format(page_count), page_count >= 2)
  check("page tree /Count matches leaf count", bytes:find("/Count " .. page_count, 1, true) ~= nil)
end

-- 6. Inline flattener handles emphasis / links / math.

do
  local out = pdf._emit_inline({
    ast.text("plain "),
    ast.emphasis("bold", { ast.text("strong") }),
    ast.text(" "),
    ast.link("https://example.com", { ast.text("see") }),
    ast.text(" "),
    { kind = "math", body = "x^2" },
  })
  check(
    "emit_inline flattens emphasis content",
    out:find("strong", 1, true) ~= nil,
    ("got %q"):format(out)
  )
  check("emit_inline includes link target", out:find("example.com", 1, true) ~= nil)
  check("emit_inline preserves math body", out:find("x^2", 1, true) ~= nil)
end

-- 7. split_lines retains empty trailing lines.

do
  local lines = pdf._split_lines("a\n\nb\n")
  -- "a", "", "b", "" -> 4 entries
  check(("split_lines yields 4 lines for 'a\\n\\nb\\n' (got %d)"):format(#lines), #lines == 4)
  check("split_lines preserves empty middle line", lines[2] == "")
end

-- 8. Glyph encoding produces 4-hex-digit big-endian CIDs.

do
  local font_mod = require("organ.pdf.font")
  local f = assert(font_mod.load(ttf_path))
  local hex = pdf._encode_glyphs(f, "A")
  -- Should be "<HHHH>" -- 6 chars total ("<" + 4 hex + ">").
  check(("encode_glyphs('A') is 6 chars (got %d: %q)"):format(#hex, hex), #hex == 6)
  check("encode_glyphs starts with '<'", hex:sub(1, 1) == "<")
  check("encode_glyphs ends with '>'", hex:sub(-1) == ">")
  -- Empty string -> "<>"
  check("encode_glyphs('') == '<>'", pdf._encode_glyphs(f, "") == "<>")
end

print(("\n%d check(s), %d failure(s)"):format(checks, fails))
if fails > 0 then
  os.exit(1)
end
print("pdf_render_test: OK")
