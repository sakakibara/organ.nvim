-- Pure unit tests for the PDF object-model writer.
-- Run via: nvim --headless -l tests/pdf_writer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local writer = require("organ.pdf.writer")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- 1. Minimal valid PDF: header + 1 catalog object.

do
  local w = writer.new()
  local root_ref = w:add({ Type = "/Catalog" })
  w:set_root(root_ref)
  local bytes = w:bytes()

  check(
    "header starts with %PDF-1.7",
    bytes:sub(1, 8) == "%PDF-1.7",
    ("got %q"):format(bytes:sub(1, 8))
  )
  -- Header layout: "%PDF-1.7\n" (9 bytes) then "%" (byte 10) then the
  -- 4 high-bit binary marker bytes at positions 11..14.
  check(
    "binary marker present (4 bytes >= 0x80 after header LF)",
    bytes:sub(11, 14) == "\xE2\xE3\xCF\xD3",
    ("got %q"):format(bytes:sub(11, 14))
  )
  check("ends with %%EOF\\n", bytes:sub(-6) == "%%EOF\n", ("got %q"):format(bytes:sub(-6)))
  check("xref subsection line '0 2'", bytes:find("\n0 2\n", 1, true) ~= nil)
  check("free object 0 entry", bytes:find("0000000000 65535 f \n", 1, true) ~= nil)
  check("contains catalog body", bytes:find("/Type /Catalog", 1, true) ~= nil)
  check("trailer references root", bytes:find("/Root 1 0 R", 1, true) ~= nil)
  check("trailer /Size 2", bytes:find("/Size 2", 1, true) ~= nil)
end

-- 2. Multiple objects: xref offsets line up with actual byte positions.

do
  local w = writer.new()
  local a = w:add({ Type = "/Catalog", Pages = writer.ref(2) })
  local b = w:add({ Type = "/Pages", Kids = writer.array({}), Count = 0 })
  local c = w:add({ Type = "/Font", Subtype = "/Type1", BaseFont = "/Helvetica" })
  w:set_root(a)
  local bytes = w:bytes()

  -- Parse xref offsets from the xref table.
  local xref_at = bytes:find("\nxref\n", 1, true)
  check("xref keyword present", xref_at ~= nil)
  -- After "\nxref\n" comes "0 4\n", then 4 entries of 20 bytes each.
  local entries_start = xref_at + #"\nxref\n" + #"0 4\n"
  local function parse_entry(idx)
    local off = entries_start + (idx * 20)
    local entry = bytes:sub(off, off + 19)
    return tonumber(entry:sub(1, 10))
  end
  local off1 = parse_entry(1)
  local off2 = parse_entry(2)
  local off3 = parse_entry(3)

  check(
    "offset 1 points at '1 0 obj'",
    bytes:sub(off1 + 1, off1 + 7) == "1 0 obj",
    ("off1=%d got=%q"):format(off1, bytes:sub(off1 + 1, off1 + 7))
  )
  check(
    "offset 2 points at '2 0 obj'",
    bytes:sub(off2 + 1, off2 + 7) == "2 0 obj",
    ("off2=%d got=%q"):format(off2, bytes:sub(off2 + 1, off2 + 7))
  )
  check(
    "offset 3 points at '3 0 obj'",
    bytes:sub(off3 + 1, off3 + 7) == "3 0 obj",
    ("off3=%d got=%q"):format(off3, bytes:sub(off3 + 1, off3 + 7))
  )

  -- startxref points at xref keyword (xref_at is the LF before 'xref').
  local startxref_str = bytes:match("startxref\n(%d+)\n")
  check(
    "startxref numeric value",
    tonumber(startxref_str) == xref_at,
    ("startxref=%s xref_at=%d"):format(startxref_str, xref_at)
  )
end

-- 3. Encoding each Lua type.

do
  local w = writer.new()
  local ref = w:add({
    Int = 42,
    Float = 1.5,
    NegInt = -7,
    Lit = "hello (world)",
    Name = "/Helvetica",
    Bool = true,
    Arr = { 1, 2, 3 },
    Nested = { Inner = "/X" },
    Refr = writer.ref(99),
  })
  w:set_root(ref)
  local bytes = w:bytes()

  check("integer encodes as decimal", bytes:find("/Int 42", 1, true) ~= nil)
  check("float without trailing zero", bytes:find("/Float 1.5", 1, true) ~= nil)
  check("negative integer", bytes:find("/NegInt %-7") ~= nil)
  check("literal string with escaped parens", bytes:find("/Lit %(hello %\\%(world%\\%)%)") ~= nil)
  check("pre-encoded name passes through", bytes:find("/Name /Helvetica", 1, true) ~= nil)
  check("boolean true", bytes:find("/Bool true", 1, true) ~= nil)
  check("array encoded", bytes:find("/Arr [ 1 2 3 ]", 1, true) ~= nil)
  check("nested dict", bytes:find("/Nested << /Inner /X >>", 1, true) ~= nil)
  check("ref encodes as 'N 0 R'", bytes:find("/Refr 99 0 R", 1, true) ~= nil)
end

-- 4. Errors on incomplete state.

do
  local w = writer.new()
  local r = w:alloc()
  w:set_root(r)
  local ok, err = pcall(function()
    return w:bytes()
  end)
  check(
    "bytes() errors when allocated ref is unset",
    not ok and tostring(err):find("never set"),
    tostring(err)
  )
end

do
  local w = writer.new()
  w:add({ Type = "/Catalog" })
  local ok, err = pcall(function()
    return w:bytes()
  end)
  check("bytes() errors without set_root", not ok and tostring(err):find("set_root"), tostring(err))
end

-- 5. Stream encoding with auto-injected /Length.

do
  local data = "BT 100 100 Td (Hello) Tj ET"
  check("stream data length is 27", #data == 27)
  local s = writer.stream(data, { Type = "/XObject" })
  local w = writer.new()
  local catalog = w:add({ Type = "/Catalog", S = w:add(s) })
  w:set_root(catalog)
  local bytes = w:bytes()
  check("stream dict carries /Length 27", bytes:find("/Length 27", 1, true) ~= nil)
  check(
    "stream keyword followed by data",
    bytes:find("stream\nBT 100 100 Td %(Hello%) Tj ET\nendstream") ~= nil
  )
  check("no /Filter injected (MVP uncompressed)", bytes:find("/Filter", 1, true) == nil)
  check("stream carries /Type /XObject", bytes:find("/Type /XObject", 1, true) ~= nil)
end

-- 6. Helpers.

do
  check("writer.name", writer.name("Foo") == "/Foo")
  check("writer.string escapes parens", writer.string("a(b)c") == "(a\\(b\\)c)")
  check("writer.string escapes backslash", writer.string("a\\b") == "(a\\\\b)")
  check("writer.hex_string", writer.hex_string("Hi") == "<4869>")
  check(
    "writer.ref",
    (function()
      local r = writer.ref(7)
      return r.num == 7
    end)()
  )
end

-- 7. Linear xref correctness with 5 objects.

do
  local w = writer.new()
  local refs = {}
  for i = 1, 5 do
    refs[i] = w:add({ ID = i, Note = "object number " .. i })
  end
  w:set_root(refs[1])
  local bytes = w:bytes()

  local xref_at = bytes:find("\nxref\n", 1, true)
  local entries_start = xref_at + #"\nxref\n" + #"0 6\n"
  local all_ok = true
  for i = 1, 5 do
    local off = tonumber(bytes:sub(entries_start + i * 20, entries_start + i * 20 + 9))
    local expect = string.format("%d 0 obj", i)
    if bytes:sub(off + 1, off + #expect) ~= expect then
      all_ok = false
      print(
        ("    object %d: off=%d expected %q got %q"):format(
          i,
          off,
          expect,
          bytes:sub(off + 1, off + #expect)
        )
      )
    end
  end
  check("all 5 xref offsets point at correct '<n> 0 obj' headers", all_ok)
end

-- 8. Empty dict / array helpers.

do
  local w = writer.new()
  local empty_dict_ref = w:add(writer.dict({}))
  local empty_arr_ref = w:add(writer.array({}))
  w:set_root(empty_dict_ref)
  local bytes = w:bytes()
  check("empty dict serializes as '<< >>'", bytes:find("<< >>", 1, true) ~= nil)
  check("empty array serializes as '[ ]'", bytes:find("%[ %]") ~= nil)
  -- Ensure we used both refs to silence linters.
  check("empty_arr_ref num is 2", empty_arr_ref.num == 2)
end

print(("\n%d check(s), %d failure(s)"):format(0, fails))
if fails > 0 then
  os.exit(1)
end
print("pdf_writer_test: OK")
