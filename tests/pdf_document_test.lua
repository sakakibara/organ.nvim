-- Pure unit tests for the PDF document scaffold (catalog + page tree
-- + pages). Run via: nvim --headless -l tests/pdf_document_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local document = require("organ.pdf.document")

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

-- 1. Single-page document: structural dicts and refs line up.

do
  local doc = document.new()
  local page_ref = doc:add_page()
  local bytes = doc:bytes()

  check("header is %PDF-1.7", bytes:sub(1, 8) == "%PDF-1.7", ("got %q"):format(bytes:sub(1, 8)))
  check("trailer ends with %%EOF\\n", bytes:sub(-6) == "%%EOF\n")
  check("contains /Type /Catalog", bytes:find("/Type /Catalog", 1, true) ~= nil)
  check("contains /Type /Pages (page tree)", bytes:find("/Type /Pages", 1, true) ~= nil)
  check("contains /Type /Page (leaf)", bytes:find("/Type /Page%s") ~= nil)
  check("page tree /Count 1", bytes:find("/Count 1", 1, true) ~= nil)
  check(
    "default MediaBox is letter 612x792",
    bytes:find("/MediaBox [ 0 0 612 792 ]", 1, true) ~= nil
  )
  check("page has empty /Resources", bytes:find("/Resources << >>", 1, true) ~= nil)

  -- Page ref should be object #3 (catalog=1, pages=2 allocated first).
  check("first page ref num is 3", page_ref.num == 3, ("got %s"):format(tostring(page_ref.num)))
  -- /Parent of page should be 2 0 R (the page tree, allocated second).
  check("page /Parent 2 0 R", bytes:find("/Parent 2 0 R", 1, true) ~= nil)
  -- Catalog's /Pages should be 2 0 R.
  check("catalog /Pages 2 0 R", bytes:find("/Pages 2 0 R", 1, true) ~= nil)
  -- Kids array should include the page.
  check("page tree /Kids [ 3 0 R ]", bytes:find("/Kids [ 3 0 R ]", 1, true) ~= nil)
  -- Trailer /Root should be the catalog (object 1).
  check("trailer /Root 1 0 R", bytes:find("/Root 1 0 R", 1, true) ~= nil)
end

-- 2. Custom page size.

do
  local doc = document.new()
  doc:add_page({ width = 100, height = 200 })
  local bytes = doc:bytes()
  check(
    "custom MediaBox uses provided dimensions",
    bytes:find("/MediaBox [ 0 0 100 200 ]", 1, true) ~= nil
  )
end

-- 3. Multiple pages: count, kids, and consistent /Parent.

do
  local doc = document.new()
  local p1 = doc:add_page()
  local p2 = doc:add_page({ width = 595, height = 842 }) -- A4
  local p3 = doc:add_page()
  local bytes = doc:bytes()

  check("three pages: /Count 3", bytes:find("/Count 3", 1, true) ~= nil)
  check(
    "three pages: /Kids [ 3 0 R 4 0 R 5 0 R ]",
    bytes:find("/Kids [ 3 0 R 4 0 R 5 0 R ]", 1, true) ~= nil
  )
  -- Each page object should declare /Parent 2 0 R. Count occurrences
  -- of that exact substring -- should be 3, one per page.
  local parent_count = 0
  for _ in bytes:gmatch("/Parent 2 0 R") do
    parent_count = parent_count + 1
  end
  check(
    "all 3 pages share /Parent 2 0 R",
    parent_count == 3,
    ("got %d occurrences"):format(parent_count)
  )
  check("page refs sequentially numbered 3,4,5", p1.num == 3 and p2.num == 4 and p3.num == 5)
  check("A4 MediaBox emitted", bytes:find("/MediaBox [ 0 0 595 842 ]", 1, true) ~= nil)
end

-- 4. Document.new exists and add_page returns a ref table.

do
  local doc = document.new()
  local r = doc:add_page()
  check("add_page returns ref-shaped table", type(r) == "table" and type(r.num) == "number")
end

-- 5. Smoke-write to /tmp to confirm reasonable size.

do
  local doc = document.new()
  doc:add_page()
  local bytes = doc:bytes()
  -- Minimal document should be under 1KB.
  check("single-page PDF is small (< 1024 bytes)", #bytes < 1024, ("size=%d"):format(#bytes))
  -- Write it out for manual inspection if desired -- not asserted.
  local f = io.open("/tmp/organ_pdf_document_test.pdf", "wb")
  if f then
    f:write(bytes)
    f:close()
  end
end

print(("\n%d check(s), %d failure(s)"):format(checks, fails))
if fails > 0 then
  os.exit(1)
end
print("pdf_document_test: OK")
