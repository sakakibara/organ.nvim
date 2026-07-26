-- Pure unit tests for the PDF JPEG image embedder.
-- Run via: nvim --headless -l tests/pdf_image_test.lua
--
-- No imagemagick / Pillow is available in the build env, so we build
-- synthetic JPEG-shaped byte streams in-test rather than committing a
-- fixture. The parser only walks segments looking for SOFn for
-- dimensions; it doesn't decode the entropy-coded scan, so a SOI +
-- SOF0 + EOI sequence is enough to exercise it. The embed() output is
-- valid PDF regardless of whether the JPEG payload would actually
-- render in a viewer.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local image = require("organ.pdf.image")
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

-- Helpers: synthesize JPEG-shaped byte sequences. SOF0 body is
-- precision(1) | height(2 BE) | width(2 BE) | nc(1) | per-component
-- block (3 bytes * nc); the trailing component blocks aren't read by
-- our parser but real JPEG layouts include them so we mimic the shape.

local function be16(n)
  return string.char(math.floor(n / 256) % 256, n % 256)
end

local function build_jpeg(width, height, nc, bits)
  bits = bits or 8
  local sof_body = string.char(bits) .. be16(height) .. be16(width) .. string.char(nc)
  for _ = 1, nc do
    sof_body = sof_body .. string.char(1, 0x11, 0) -- id, sampling, qt-id
  end
  local sof_len = #sof_body + 2 -- includes the 2 length bytes
  local sof = "\xFF\xC0" .. be16(sof_len) .. sof_body
  return "\xFF\xD8" .. sof .. "\xFF\xD9"
end

local function write_tmp(bytes)
  local path = vim.fn.tempname() .. ".jpg"
  local fh = assert(io.open(path, "wb"))
  fh:write(bytes)
  fh:close()
  return path
end

-- 1. Non-JPEG inputs are rejected.

do
  local path = vim.fn.tempname() .. ".bin"
  local fh = assert(io.open(path, "wb"))
  fh:write("\x89PNG\r\n\x1A\n" .. string.rep("\0", 32))
  fh:close()
  local img, err = image.load_jpeg(path)
  check("non-JPEG returns nil", img == nil)
  check("non-JPEG carries error", type(err) == "string" and err:find("SOI", 1, true) ~= nil)
end

-- 2. Missing file returns nil + error.

do
  local img, err = image.load_jpeg("/nonexistent/path/does/not/exist.jpg")
  check("missing file returns nil", img == nil)
  check("missing file carries error", type(err) == "string")
end

-- 3. Truncated / empty file rejected.

do
  local path = vim.fn.tempname() .. ".jpg"
  local fh = assert(io.open(path, "wb"))
  fh:write("\xFF")
  fh:close()
  local img, err = image.load_jpeg(path)
  check("tiny file rejected", img == nil and type(err) == "string")
end

-- 4. 8x8 RGB: parses width/height/components correctly.

do
  local path = write_tmp(build_jpeg(8, 8, 3))
  local img, err = image.load_jpeg(path)
  check("8x8 RGB loads", img ~= nil, err)
  if img then
    check("width = 8", img.width == 8, "got " .. tostring(img.width))
    check("height = 8", img.height == 8, "got " .. tostring(img.height))
    check("color_components = 3", img.color_components == 3)
    check("bits_per_component = 8", img.bits_per_component == 8)
    check("bytes start with SOI", img.bytes:sub(1, 2) == "\xFF\xD8")
  end
end

-- 5. Non-square 200x100 RGB: dimensions distinguish width vs height.

do
  local path = write_tmp(build_jpeg(200, 100, 3))
  local img = assert(image.load_jpeg(path))
  check("200x100 width correct", img.width == 200, "got " .. tostring(img.width))
  check("200x100 height correct", img.height == 100, "got " .. tostring(img.height))
end

-- 6. Embed an 8x8 RGB JPEG into a writer.

do
  local jpeg_bytes = build_jpeg(8, 8, 3)
  local path = write_tmp(jpeg_bytes)
  local img = assert(image.load_jpeg(path))

  local w = writer.new()
  local catalog = w:add({ Type = "/Catalog" })
  local img_ref = img:embed(w)
  w:set_root(catalog)

  check("embed returns a ref", type(img_ref) == "table" and type(img_ref.num) == "number")

  local bytes = w:bytes()
  check("contains /Type /XObject", bytes:find("/Type /XObject", 1, true) ~= nil)
  check("contains /Subtype /Image", bytes:find("/Subtype /Image", 1, true) ~= nil)
  check("contains /Width 8", bytes:find("/Width 8", 1, true) ~= nil)
  check("contains /Height 8", bytes:find("/Height 8", 1, true) ~= nil)
  check("contains /Filter /DCTDecode", bytes:find("/Filter /DCTDecode", 1, true) ~= nil)
  check("contains /ColorSpace /DeviceRGB", bytes:find("/ColorSpace /DeviceRGB", 1, true) ~= nil)
  check("contains /BitsPerComponent 8", bytes:find("/BitsPerComponent 8", 1, true) ~= nil)
  check(
    "/Length matches JPEG byte count",
    bytes:find("/Length " .. tostring(#jpeg_bytes), 1, true) ~= nil,
    "expected /Length " .. tostring(#jpeg_bytes)
  )
  -- Raw JPEG bytes appear verbatim inside the stream.
  check("stream contains raw SOI marker", bytes:find("stream\n\xFF\xD8", 1, true) ~= nil)
  check("stream ends with EOI before endstream", bytes:find("\xFF\xD9\nendstream", 1, true) ~= nil)
end

-- 7. Grayscale (1 component) -> /DeviceGray.

do
  local path = write_tmp(build_jpeg(16, 16, 1))
  local img = assert(image.load_jpeg(path))
  check("grayscale color_components = 1", img.color_components == 1)

  local w = writer.new()
  local catalog = w:add({ Type = "/Catalog" })
  img:embed(w)
  w:set_root(catalog)
  local bytes = w:bytes()
  check(
    "grayscale -> /ColorSpace /DeviceGray",
    bytes:find("/ColorSpace /DeviceGray", 1, true) ~= nil
  )
  check("grayscale does NOT emit /DeviceRGB", bytes:find("/ColorSpace /DeviceRGB", 1, true) == nil)
end

-- 8. CMYK (4 components) -> /DeviceCMYK.

do
  local path = write_tmp(build_jpeg(32, 16, 4))
  local img = assert(image.load_jpeg(path))
  check("CMYK color_components = 4", img.color_components == 4)

  local w = writer.new()
  local catalog = w:add({ Type = "/Catalog" })
  img:embed(w)
  w:set_root(catalog)
  local bytes = w:bytes()
  check("CMYK -> /ColorSpace /DeviceCMYK", bytes:find("/ColorSpace /DeviceCMYK", 1, true) ~= nil)
end

-- 9. SOF2 (progressive) is accepted, not just SOF0.

do
  local sof_body = string.char(8) .. be16(24) .. be16(48) .. string.char(3)
  for _ = 1, 3 do
    sof_body = sof_body .. string.char(1, 0x11, 0)
  end
  local sof_len = #sof_body + 2
  local jpeg = "\xFF\xD8" .. "\xFF\xC2" .. be16(sof_len) .. sof_body .. "\xFF\xD9"
  local path = write_tmp(jpeg)
  local img, err = image.load_jpeg(path)
  check("progressive (SOF2) loads", img ~= nil, err)
  if img then
    check("progressive width", img.width == 48)
    check("progressive height", img.height == 24)
  end
end

-- 10. APP0 / DQT segments before SOF are skipped.

do
  -- Build a JPEG with an APP0 segment (JFIF marker) then a DQT-sized
  -- dummy segment, then SOF0. Our parser must walk past both.
  local app0_body = "JFIF\0" .. string.char(1, 1, 0) .. be16(72) .. be16(72) .. string.char(0, 0)
  local app0_len = #app0_body + 2
  local app0 = "\xFF\xE0" .. be16(app0_len) .. app0_body

  local dqt_body = string.rep("\0", 65) -- precision/id + 64 table entries
  local dqt_len = #dqt_body + 2
  local dqt = "\xFF\xDB" .. be16(dqt_len) .. dqt_body

  local sof_body = string.char(8) .. be16(64) .. be16(128) .. string.char(3)
  for _ = 1, 3 do
    sof_body = sof_body .. string.char(1, 0x11, 0)
  end
  local sof_len = #sof_body + 2
  local sof = "\xFF\xC0" .. be16(sof_len) .. sof_body

  local jpeg = "\xFF\xD8" .. app0 .. dqt .. sof .. "\xFF\xD9"
  local path = write_tmp(jpeg)
  local img, err = image.load_jpeg(path)
  check("APP0+DQT preamble parsed past", img ~= nil, err)
  if img then
    check("post-preamble width", img.width == 128)
    check("post-preamble height", img.height == 64)
  end
end

-- 11. JPEG with no SOF segment is rejected.

do
  -- Just SOI + APP0 + EOI -- no frame header.
  local app0_body = "JFIF\0" .. string.char(1, 1, 0) .. be16(72) .. be16(72) .. string.char(0, 0)
  local app0_len = #app0_body + 2
  local app0 = "\xFF\xE0" .. be16(app0_len) .. app0_body
  local jpeg = "\xFF\xD8" .. app0 .. "\xFF\xD9"
  local path = write_tmp(jpeg)
  local img, err = image.load_jpeg(path)
  check("no-SOF rejected", img == nil)
  check("no-SOF error mentions SOF", type(err) == "string" and err:find("SOF", 1, true) ~= nil)
end

if fails > 0 then
  print(("\n%d failure(s)"):format(fails))
  os.exit(1)
end
print("\nall pdf_image_test checks passed")
