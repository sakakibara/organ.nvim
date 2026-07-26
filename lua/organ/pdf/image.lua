-- Pure-Lua JPEG passthrough for PDF /XObject embedding.
--
-- A PDF reader can decode a JPEG directly when the image XObject uses
-- /Filter /DCTDecode -- the JPEG bytes are streamed in verbatim, no
-- re-encoding. This is the cheapest possible image embed and the only
-- one supported here. PNG and other formats need DEFLATE (out of MVP
-- scope) or a third-party decoder (against the no-deps policy).
--
-- Walks JPEG segments (FFD8 SOI, FFxx <len> <data>, ..., FFD9 EOI) to
-- find the first SOFn (Start Of Frame) for dimensions and component
-- count. Doesn't decode pixel data; doesn't validate the entire file.
--
-- Public surface:
--
--   local image = require("organ.pdf.image")
--   local img, err = image.load_jpeg("/path/to/photo.jpg")
--   -- img: { width, height, color_components, bits_per_component, bytes }
--   local ref = img:embed(writer)
--
-- embed() returns an XObject ref; installing it in any page's
-- /Resources /XObject dict is the caller's responsibility.

local writer = require("organ.pdf.writer")

local M = {}

-- File loader.

local function read_all(path)
  local fh, err = io.open(path, "rb")
  if not fh then
    return nil, err
  end
  local data = fh:read("*a")
  fh:close()
  return data
end

-- JPEG segment walker.

-- Markers without a length payload: SOI (D8), EOI (D9), TEM (01), and
-- RSTn (D0..D7). Everything else (when it's a real marker, i.e. not
-- the FF00 stuffing byte) carries a 2-byte big-endian length that
-- INCLUDES the two length bytes themselves.
local function is_standalone(marker)
  return marker == 0xD8 or marker == 0xD9 or marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)
end

-- SOF markers we read dimensions from. SOF0 (baseline), SOF1 (extended
-- sequential), SOF2 (progressive) all have the same body layout and
-- all are valid /DCTDecode sources. SOF3/5/6/7/9.. are lossless or
-- arithmetic-coded variants -- rare, and PDF readers may not accept
-- them, but we read dims uniformly and let the reader decide.
local function is_sof(marker)
  if marker == 0xC0 or marker == 0xC1 or marker == 0xC2 then
    return true
  end
  if marker == 0xC3 then
    return true
  end
  if marker >= 0xC5 and marker <= 0xC7 then
    return true
  end
  if marker >= 0xC9 and marker <= 0xCB then
    return true
  end
  if marker >= 0xCD and marker <= 0xCF then
    return true
  end
  return false
end

local function parse_jpeg(data)
  if #data < 4 then
    return nil, "not a JPEG: file too small"
  end
  if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then
    return nil, "not a JPEG: missing SOI marker"
  end

  local pos = 3 -- past SOI
  local width, height, bits, ncomp
  while pos <= #data do
    if data:byte(pos) ~= 0xFF then
      return nil, "malformed JPEG: expected marker prefix 0xFF at offset " .. (pos - 1)
    end
    -- Skip fill bytes: a marker can be preceded by any number of 0xFF
    -- padding bytes. Walk past them to the actual marker code.
    local marker_pos = pos + 1
    while marker_pos <= #data and data:byte(marker_pos) == 0xFF do
      marker_pos = marker_pos + 1
    end
    if marker_pos > #data then
      return nil, "truncated JPEG: marker without code"
    end
    local marker = data:byte(marker_pos)
    pos = marker_pos + 1

    if marker == 0xD9 then -- EOI
      break
    end
    if is_standalone(marker) then
      -- No length, no payload.
    else
      if pos + 1 > #data then
        return nil, "truncated JPEG: missing segment length"
      end
      local seg_len = data:byte(pos) * 256 + data:byte(pos + 1)
      if seg_len < 2 then
        return nil, "malformed JPEG: segment length < 2"
      end
      if pos + seg_len - 1 > #data then
        return nil, "truncated JPEG: segment runs past end of file"
      end
      if is_sof(marker) and not width then
        -- SOF body: precision (1) | height (2) | width (2) | nc (1).
        if seg_len < 8 then
          return nil, "malformed JPEG: SOF segment too short"
        end
        bits = data:byte(pos + 2)
        height = data:byte(pos + 3) * 256 + data:byte(pos + 4)
        width = data:byte(pos + 5) * 256 + data:byte(pos + 6)
        ncomp = data:byte(pos + 7)
      end
      pos = pos + seg_len
      if marker == 0xDA then
        -- SOS (Start Of Scan): entropy-coded data follows, not segments.
        -- We've already read the SOF (which always precedes SOS in a
        -- valid JPEG), so we can stop walking here.
        break
      end
    end
  end

  if not width then
    return nil, "no SOF segment found (not a baseline/progressive JPEG?)"
  end
  if ncomp ~= 1 and ncomp ~= 3 and ncomp ~= 4 then
    return nil, "unsupported JPEG component count: " .. tostring(ncomp)
  end
  return {
    width = width,
    height = height,
    bits_per_component = bits,
    color_components = ncomp,
  }
end

-- Image object.

local Image = {}
Image.__index = Image

local function color_space_for(nc)
  if nc == 1 then
    return "/DeviceGray"
  elseif nc == 4 then
    return "/DeviceCMYK"
  end
  return "/DeviceRGB"
end

-- Emit the image as a stream XObject and return its ref. The caller is
-- responsible for adding the ref to a page's /Resources /XObject dict
-- under whatever name they choose (e.g. /Im1).
function Image:embed(w)
  local extra = {
    Type = "/XObject",
    Subtype = "/Image",
    Width = self.width,
    Height = self.height,
    ColorSpace = color_space_for(self.color_components),
    BitsPerComponent = self.bits_per_component,
    Filter = "/DCTDecode",
  }
  return w:add(writer.stream(self.bytes, extra))
end

-- Public loader.

function M.load_jpeg(path)
  local data, err = read_all(path)
  if not data then
    return nil, err
  end
  local info, perr = parse_jpeg(data)
  if not info then
    return nil, perr
  end
  return setmetatable({
    width = info.width,
    height = info.height,
    color_components = info.color_components,
    bits_per_component = info.bits_per_component,
    bytes = data,
  }, Image)
end

M.Image = Image

return M
