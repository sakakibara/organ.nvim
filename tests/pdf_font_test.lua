-- Pure-Lua TTF parser + PDF Type0/CIDFontType2 embedding unit tests.
-- Run via: nvim --headless -l tests/pdf_font_test.lua
--
-- Needs a system TTF to drive the parser. Skips cleanly if none is
-- found -- CI environments without fonts shouldn't fail the suite.

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
    "/System/Library/Fonts/Helvetica.ttc", -- .ttc unsupported, last resort
  }
  for _, p in ipairs(candidates) do
    if vim.uv.fs_stat(p) then
      -- Skip .ttc collections (the parser only handles single-face .ttf).
      if not p:lower():match("%.ttc$") then
        return p
      end
    end
  end
  return nil
end

local ttf_path = find_ttf()
if not ttf_path then
  print("(skipped: no system TTF found)")
  print("pdf_font_test: SKIP")
  os.exit(0)
end

print(("(using font: %s)"):format(ttf_path))

local font = require("organ.pdf.font")
local writer = require("organ.pdf.writer")

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

----------------------------------------------------------------------
-- 1. font.load + name extraction.

local f, err = font.load(ttf_path)
check("font.load returns a non-nil object", f ~= nil, ("err=%s"):format(tostring(err)))

if not f then
  print("\nCannot continue: load failed.")
  os.exit(1)
end

check(
  "postscript_name is non-empty string",
  type(f.postscript_name) == "string" and #f.postscript_name > 0,
  ("got %q"):format(tostring(f.postscript_name))
)
check(
  "full_name is non-empty string",
  type(f.full_name) == "string" and #f.full_name > 0,
  ("got %q"):format(tostring(f.full_name))
)
check("font:gid is callable", type(f.gid) == "function")
check("font:width is callable", type(f.width) == "function")

----------------------------------------------------------------------
-- 2. cmap lookup behaviour.

local gid_A = f:gid(0x41) -- 'A'
check(
  "gid for U+0041 ('A') is non-zero",
  type(gid_A) == "number" and gid_A > 0,
  ("got %s"):format(tostring(gid_A))
)

local gid_notdef = f:gid(0xFFFE) -- intentionally unmapped
check("gid for U+FFFE (unmapped) is 0", gid_notdef == 0, ("got %s"):format(tostring(gid_notdef)))

local gid_space = f:gid(0x20)
check("gid for U+0020 (space) is non-zero", type(gid_space) == "number" and gid_space > 0)

----------------------------------------------------------------------
-- 3. width lookup.

local w_A = f:width(gid_A)
check(
  "width for 'A' glyph is in 1/1000-em sanity range (200..2000)",
  type(w_A) == "number" and w_A >= 200 and w_A <= 2000,
  ("got %s"):format(tostring(w_A))
)

-- Width for glyph 0 (.notdef) should still return a number (not nil).
local w_notdef = f:width(0)
check("width for gid 0 (.notdef) returns a number", type(w_notdef) == "number")

----------------------------------------------------------------------
-- 4. Embed into a writer and inspect the produced bytes.

local w = writer.new()
local catalog = w:alloc()
local font_ref = f:embed(w)
check("embed returns a ref table", type(font_ref) == "table" and type(font_ref.num) == "number")

-- Wire up a minimal valid PDF so we can call :bytes() and inspect.
w:set(catalog, { Type = "/Catalog", Font = font_ref })
w:set_root(catalog)
local bytes = w:bytes()

check("output contains /Type /Font", bytes:find("/Type /Font", 1, true) ~= nil)
check("output contains /Subtype /Type0", bytes:find("/Subtype /Type0", 1, true) ~= nil)
check(
  "output contains /Subtype /CIDFontType2",
  bytes:find("/Subtype /CIDFontType2", 1, true) ~= nil
)
check("output contains /Encoding /Identity-H", bytes:find("/Encoding /Identity-H", 1, true) ~= nil)
check("output contains /FontDescriptor", bytes:find("/FontDescriptor", 1, true) ~= nil)
check("output contains /FontFile2", bytes:find("/FontFile2", 1, true) ~= nil)
check("output contains /ToUnicode", bytes:find("/ToUnicode", 1, true) ~= nil)
check(
  "output contains /CIDToGIDMap /Identity",
  bytes:find("/CIDToGIDMap /Identity", 1, true) ~= nil
)

----------------------------------------------------------------------
-- 5. /FontFile2 stream's /Length1 equals the on-disk TTF size.

local ttf_size = vim.uv.fs_stat(ttf_path).size
check(
  ("FontFile2 /Length1 equals TTF size (%d)"):format(ttf_size),
  bytes:find("/Length1 " .. tostring(ttf_size), 1, true) ~= nil,
  ("did not find /Length1 %d in output"):format(ttf_size)
)

----------------------------------------------------------------------
-- 6. ToUnicode CMap contains expected PostScript-flavoured CMap markers.

check("ToUnicode contains beginbfchar", bytes:find("beginbfchar", 1, true) ~= nil)
check("ToUnicode contains endbfchar", bytes:find("endbfchar", 1, true) ~= nil)
check("ToUnicode contains begincodespacerange", bytes:find("begincodespacerange", 1, true) ~= nil)
check(
  "ToUnicode contains /Registry (Adobe) /Ordering (UCS)",
  bytes:find("/Ordering %(UCS%)") ~= nil
)

----------------------------------------------------------------------
-- 7. CIDFontType2 W array is present.

check("CIDFontType2 carries a /W array", bytes:find("/W [", 1, true) ~= nil)

----------------------------------------------------------------------
-- 8. /BaseFont uses the (sanitized) PostScript name.

local pat = "/BaseFont /" .. f.postscript_name:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
local m = bytes:find(pat)
check(
  ("/BaseFont uses postscript name (/%s)"):format(f.postscript_name),
  m ~= nil,
  ("looking for: %s"):format(pat)
)

----------------------------------------------------------------------
-- 9. Cmap pair sanity: pair count > 0 and ToUnicode has at least one
-- bfchar entry mapping a gid to a hex codepoint.

check(
  "ToUnicode contains at least one <hex> <hex> bfchar entry",
  bytes:find("<%x%x%x%x>%s+<%x%x%x%x>") ~= nil
)

----------------------------------------------------------------------

print(("\n%d check(s), %d failure(s)"):format(checks, fails))
if fails > 0 then
  os.exit(1)
end
print("pdf_font_test: OK")
