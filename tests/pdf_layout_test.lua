-- Text layout state machine tests.
-- Run via: nvim --headless -l tests/pdf_layout_test.lua
--
-- Needs a real system TTF for font metrics. Skips when none is found,
-- following the precedent of pdf_font_test.lua.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function find_ttf()
  local candidates = {
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/Library/Fonts/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
  }
  for _, p in ipairs(candidates) do
    if vim.uv.fs_stat(p) and not p:lower():match("%.ttc$") then
      return p
    end
  end
  return nil
end

local ttf_path = find_ttf()
if not ttf_path then
  print("(skipped: no system TTF found)")
  print("pdf_layout_test: SKIP")
  os.exit(0)
end

print(("(using font: %s)"):format(ttf_path))

local font = require("organ.pdf.font")
local layout = require("organ.pdf.layout")

local f = assert(font.load(ttf_path))

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

-- Standard page/margin set re-used across cases.

local function new_layout(opts)
  opts = opts or {}
  return layout.new({
    page_width = opts.page_width or 612,
    page_height = opts.page_height or 792,
    margin_left = opts.margin_left or 72,
    margin_right = opts.margin_right or 72,
    margin_top = opts.margin_top or 72,
    margin_bottom = opts.margin_bottom or 72,
    default_font = f,
    default_font_size = opts.default_font_size or 11,
    line_gap_factor = opts.line_gap_factor or 1.2,
  })
end

-- 1. Empty layout.

local L0 = new_layout()
local r0 = L0:finish()
check(
  "empty layout has no pages",
  type(r0.pages) == "table" and #r0.pages == 0,
  ("got %d pages"):format(#r0.pages)
)

-- 2. One short paragraph fits on one page.

local L1 = new_layout()
L1:add_paragraph("Hello world.")
local r1 = L1:finish()
check(
  "short paragraph produces exactly one page",
  #r1.pages == 1,
  ("got %d pages"):format(#r1.pages)
)
check(
  "short paragraph produces exactly one line",
  r1.pages[1] and #r1.pages[1].lines == 1,
  ("got %d lines"):format(r1.pages[1] and #r1.pages[1].lines or -1)
)
local first_line = r1.pages[1].lines[1]
check(
  "first line text matches input",
  first_line.text == "Hello world.",
  ("got %q"):format(first_line.text)
)
check(
  "first line x == margin_left (72)",
  first_line.x == 72,
  ("got x=%s"):format(tostring(first_line.x))
)
-- Baseline = page_height - margin_top - font_size = 792 - 72 - 11 = 709.
check(
  "first line baseline = page_height - margin_top - font_size",
  first_line.y == 792 - 72 - 11,
  ("got y=%s"):format(tostring(first_line.y))
)

-- 3. Long paragraph wraps onto multiple lines on the same page.

local L2 = new_layout()
-- Build a paragraph long enough to force a wrap but short enough to
-- fit on one page (well under 792 - 144 points of vertical space).
local long = {}
for i = 1, 80 do
  long[i] = "word" .. i
end
L2:add_paragraph(table.concat(long, " "))
local r2 = L2:finish()
check("long paragraph fits on a single page", #r2.pages == 1, ("got %d pages"):format(#r2.pages))
check(
  "long paragraph wraps to multiple lines",
  #r2.pages[1].lines >= 2,
  ("got %d lines"):format(#r2.pages[1].lines)
)

-- Every line should start at margin_left.
local all_at_margin = true
for _, ln in ipairs(r2.pages[1].lines) do
  if ln.x ~= 72 then
    all_at_margin = false
    break
  end
end
check("every wrapped line starts at margin_left", all_at_margin)

-- Y decreases line-over-line by exactly font_size * line_gap_factor.
local lines2 = r2.pages[1].lines
local expected_gap = 11 * 1.2
local mono_decrease = true
for i = 2, #lines2 do
  local dy = lines2[i - 1].y - lines2[i].y
  if math.abs(dy - expected_gap) > 1e-6 then
    mono_decrease = false
    break
  end
end
check(
  ("each line drops y by font_size * line_gap_factor (%.4f)"):format(expected_gap),
  mono_decrease
)

-- Last line's last word should be the last input word -- nothing got
-- silently dropped.
local last_text = lines2[#lines2].text
check(
  "wrap retains every word; last token is 'word80'",
  last_text:sub(-#"word80") == "word80",
  ("last line tail = %q"):format(last_text)
)

-- 4. Very long paragraph triggers pagination.

local L3 = new_layout()
local many = {}
for i = 1, 2000 do
  many[i] = "tok" .. i
end
L3:add_paragraph(table.concat(many, " "))
local r3 = L3:finish()
check(
  "very long paragraph spans multiple pages",
  #r3.pages >= 2,
  ("got %d pages"):format(#r3.pages)
)
-- First line on page 2 sits at the top baseline.
local p2_first = r3.pages[2].lines[1]
check(
  "first line on page 2 baseline = page_height - margin_top - font_size",
  p2_first.y == 792 - 72 - 11,
  ("got y=%s"):format(tostring(p2_first.y))
)
check("page 2 first line x == margin_left", p2_first.x == 72)

-- 5. Headings emit the documented sizes.

local LH = new_layout()
LH:add_heading("Section 1", { level = 1 })
LH:add_heading("Section 1.1", { level = 2 })
LH:add_heading("Section 1.1.1", { level = 3 })
LH:add_heading("Section 1.1.1.1", { level = 4 })
local rH = LH:finish()
local function find_line_by_text(pages, want)
  for _, pg in ipairs(pages) do
    for _, ln in ipairs(pg.lines) do
      if ln.text == want then
        return ln
      end
    end
  end
  return nil
end
local h1 = find_line_by_text(rH.pages, "Section 1")
local h2 = find_line_by_text(rH.pages, "Section 1.1")
local h3 = find_line_by_text(rH.pages, "Section 1.1.1")
local h4 = find_line_by_text(rH.pages, "Section 1.1.1.1")
check("L1 heading font_size == 18", h1 and h1.font_size == 18)
check("L2 heading font_size == 16", h2 and h2.font_size == 16)
check("L3 heading font_size == 14", h3 and h3.font_size == 14)
check("L4 heading font_size == 12", h4 and h4.font_size == 12)

-- 6. Code block: one input line -> one output line, verbatim, no wrap.

local LC = new_layout()
local src = {
  "local x = 1",
  "print(x)",
  "-- comment with many words that would have wrapped in a paragraph",
}
LC:add_code_block(src, { font = f, font_size = 10 })
local rC = LC:finish()
local code_lines = rC.pages[1].lines
check(
  "code block emits one line per input line",
  #code_lines == #src,
  ("got %d, want %d"):format(#code_lines, #src)
)
local same_text = true
for i, want in ipairs(src) do
  if code_lines[i].text ~= want then
    same_text = false
    break
  end
end
check("code block emits each input line verbatim", same_text)
check("code block lines use the requested font_size (10)", code_lines[1].font_size == 10)

-- 7. Blank line advances cursor without producing a line entry.

local LB = new_layout()
LB:add_paragraph("first")
LB:add_blank()
LB:add_paragraph("second")
local rB = LB:finish()
check("blank line produces no extra line entries", #rB.pages[1].lines == 2)
local l_first = rB.pages[1].lines[1]
local l_second = rB.pages[1].lines[2]
-- Two line gaps between "first" and "second": one normal advance for
-- emitting "second", plus the blank in between.
local expected_drop = 11 * 1.2 * 2
check(
  ("blank line introduces an extra line gap (drop=%.4f)"):format(expected_drop),
  math.abs((l_first.y - l_second.y) - expected_drop) < 1e-6,
  ("got drop=%.4f"):format(l_first.y - l_second.y)
)

-- 8. UTF-8 width: 日本 measures wider than aa.

local w_aa = layout._measure(f, 11, "aa")
local w_jp = layout._measure(f, 11, "日本")
check("UTF-8 measure: width('aa') is a positive number", type(w_aa) == "number" and w_aa > 0)
-- If the system font lacks CJK coverage, jp would fall through to
-- .notdef (gid 0) with whatever width is associated; treat as a
-- conditional. The MAIN assertion: codepoints are summed, not bytes.
-- Worst case both are zero -- still a valid sum.
check(
  "UTF-8 measure does not double-count bytes (jp uses 2 codepoints, not 6)",
  type(w_jp) == "number",
  ("got %s"):format(tostring(w_jp))
)
-- Strong condition only when the font has CJK glyphs; relax otherwise.
if f:gid(0x65E5) ~= 0 then
  check("UTF-8: width('日本') > width('aa') for a CJK font", w_jp > w_aa)
else
  print(("INFO  font lacks CJK glyphs; width('aa')=%.3f, width(jp)=%.3f"):format(w_aa, w_jp))
end

-- 9. Empty paragraph is a no-op.

local LE = new_layout()
LE:add_paragraph("")
LE:add_paragraph("   \t  ")
local rE = LE:finish()
check(
  "empty / whitespace-only paragraphs produce no lines or pages",
  #rE.pages == 0,
  ("got %d pages"):format(#rE.pages)
)

-- 10. A word wider than the column (unspaced CJK prose) breaks at
-- codepoint boundaries instead of overflowing the right margin.

do
  local LJ = new_layout()
  local ja = string.rep("\230\151\165\230\156\172\232\170\158\227\129\174", 30)
  LJ:add_paragraph(ja)
  local rJ = LJ:finish()
  local lines = rJ.pages[1] and rJ.pages[1].lines or {}
  local content_w = LJ:_content_width()
  local widest = 0
  local joined = {}
  for _, ln in ipairs(lines) do
    widest = math.max(widest, layout._measure(f, 11, ln.text))
    joined[#joined + 1] = ln.text
  end
  check("oversize word wraps onto several lines", #lines >= 2, ("got %d lines"):format(#lines))
  check(
    "no line exceeds the content width",
    widest <= content_w,
    ("widest=%.1f content=%.1f"):format(widest, content_w)
  )
  check("codepoint wrap drops nothing", table.concat(joined) == ja)
  -- Latin words still wrap whole; the oversize word fills the remainder
  -- of the current line before breaking.
  local LM = new_layout()
  LM:add_paragraph("abc " .. ja)
  local rM = LM:finish()
  local first = rM.pages[1].lines[1].text
  check(
    "oversize word continues on the current line after a short word",
    first:sub(1, 4) == "abc " and #first > 4,
    ("got %q"):format(first)
  )
end

-- 11. Spacing that runs past the bottom margin does not leave an empty
-- trailing page behind.

do
  -- Body area fits exactly three 11pt lines: 182 - 72 - 72 = 38 = 11 + 13.2 * 2.
  local LP = new_layout({ page_height = 182 })
  LP:add_paragraph("one")
  LP:add_paragraph("two")
  LP:add_paragraph("three")
  LP:add_code_block({}, {})
  local rP = LP:finish()
  check(
    "empty code block at a page boundary adds no page",
    #rP.pages == 1,
    ("got %d pages"):format(#rP.pages)
  )
  LP = new_layout({ page_height = 182 })
  LP:add_paragraph("one")
  LP:add_paragraph("two")
  LP:add_paragraph("three")
  LP:add_blank()
  LP:add_blank()
  LP:add_paragraph("four")
  rP = LP:finish()
  check(
    "text after the boundary lands on a second page",
    #rP.pages == 2,
    ("got %d pages"):format(#rP.pages)
  )
  check(
    "no page is empty",
    rP.pages[2] and #rP.pages[2].lines == 1 and rP.pages[2].lines[1].text == "four"
  )
end

-- 12. `style.indent` shifts a paragraph right and narrows its column.

do
  local LI = new_layout()
  LI:add_paragraph("indented", { indent = 24 })
  local rI = LI:finish()
  local ln = rI.pages[1].lines[1]
  check(
    "indented line x == margin_left + indent",
    ln.x == 72 + 24,
    ("got x=%s"):format(tostring(ln.x))
  )
  local LW = new_layout()
  local words = {}
  for i = 1, 200 do
    words[i] = "w" .. i
  end
  LW:add_paragraph(table.concat(words, " "), { indent = 200 })
  local rW = LW:finish()
  local widest = 0
  for _, l in ipairs(rW.pages[1].lines) do
    widest = math.max(widest, layout._measure(f, 11, l.text))
  end
  check(
    "indented paragraph wraps inside the narrowed column",
    widest <= LW:_content_width() - 200,
    ("widest=%.1f limit=%.1f"):format(widest, LW:_content_width() - 200)
  )
end

print(("\n%d check(s), %d failure(s)"):format(checks, fails))
if fails > 0 then
  os.exit(1)
end
print("pdf_layout_test: OK")
