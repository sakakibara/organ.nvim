-- Pure-Lua TrueType parser + PDF Type0 / CIDFontType2 embedding.
--
-- Parses the structural tables of a .ttf needed to embed it as a
-- composite font in a PDF (PDF 1.7 9.7): name, head, hhea, hmtx, maxp,
-- cmap (format 4), OS/2, post. Other tables (glyf, loca, cvt, fpgm,
-- prep, gasp, ...) are NOT decoded -- the full file is embedded as a
-- /FontFile2 stream and rendering is left to the PDF reader.
--
-- BMP coverage only (U+0000-U+FFFF) via cmap subtable format 4. No
-- subsetting: the entire .ttf is embedded. SMP / format 12 / format 6
-- coverage and glyph-subset extraction are out of scope here and
-- belong in a follow-up.
--
-- Public surface:
--
--   local font = require("organ.pdf.font")
--   local f = assert(font.load(path))
--   local gid = f:gid(codepoint)        -- 0 = .notdef
--   local w   = f:width(gid)            -- 1/1000-of-em units
--   f.postscript_name, f.full_name      -- strings extracted from name
--   local ref = f:embed(writer)         -- returns Type0 font ref

local writer = require("organ.pdf.writer")

local M = {}

-- Big-endian primitive readers. `o` is 1-indexed (Lua string offsets).

local byte = string.byte
local sub = string.sub

local function u16(b, o)
  local a, c = byte(b, o, o + 1)
  return a * 256 + c
end

local function u32(b, o)
  local a, c, d, e = byte(b, o, o + 3)
  return a * 16777216 + c * 65536 + d * 256 + e
end

local function s16(b, o)
  local v = u16(b, o)
  if v >= 32768 then
    v = v - 65536
  end
  return v
end

-- TrueType fixed (16.16). For italicAngle and similar, only the signed
-- integer part is needed in PDF; return as Lua number.
local function fixed(b, o)
  local hi = s16(b, o)
  local lo = u16(b, o + 2)
  return hi + lo / 65536
end

-- TTF file loader.

local function read_all(path)
  local fh, err = io.open(path, "rb")
  if not fh then
    return nil, err
  end
  local data = fh:read("*a")
  fh:close()
  return data
end

-- Parse the table directory: 12-byte font header then N x 16-byte
-- entries. Returns a map { tag = { offset = O, length = L } }.
local function parse_table_directory(data)
  if #data < 12 then
    return nil, "file too small for TTF header"
  end
  local scaler = u32(data, 1)
  -- 0x00010000 = TTF, 0x4F54544F = "OTTO" (OpenType with CFF -- not supported here),
  -- 0x74727565 = "true" (Apple TTF variant).
  if scaler ~= 0x00010000 and scaler ~= 0x74727565 then
    return nil,
      ("unsupported font sfnt version 0x%08X (only TrueType outlines accepted)"):format(scaler)
  end
  local num_tables = u16(data, 5)
  local tables = {}
  for i = 0, num_tables - 1 do
    local entry_off = 12 + i * 16 + 1
    local tag = sub(data, entry_off, entry_off + 3)
    local offset = u32(data, entry_off + 8)
    local length = u32(data, entry_off + 12)
    tables[tag] = { offset = offset + 1, length = length } -- 1-indexed
  end
  return tables
end

-- Per-table parsers. Each returns a small table of values; missing /
-- corrupt fields fall back to sensible defaults rather than erroring,
-- to be tolerant of slightly-off fonts (PDF readers themselves are
-- famously forgiving here).

local function parse_head(data, t)
  local o = t.offset
  return {
    units_per_em = u16(data, o + 18),
    x_min = s16(data, o + 36),
    y_min = s16(data, o + 38),
    x_max = s16(data, o + 40),
    y_max = s16(data, o + 42),
    mac_style = u16(data, o + 44),
  }
end

local function parse_hhea(data, t)
  local o = t.offset
  return {
    ascent = s16(data, o + 4),
    descent = s16(data, o + 6),
    line_gap = s16(data, o + 8),
    num_h_metrics = u16(data, o + 34),
  }
end

local function parse_maxp(data, t)
  local o = t.offset
  return { num_glyphs = u16(data, o + 4) }
end

-- hmtx: numberOfHMetrics x (u16 advanceWidth + s16 lsb), then
-- (numGlyphs - numberOfHMetrics) x s16 lsb. Glyphs past the metric
-- array share the LAST advance.
local function parse_hmtx(data, t, num_h_metrics, num_glyphs)
  local widths = {}
  local o = t.offset
  for i = 0, num_h_metrics - 1 do
    widths[i] = u16(data, o + i * 4)
  end
  local last = widths[num_h_metrics - 1] or 0
  for i = num_h_metrics, num_glyphs - 1 do
    widths[i] = last
  end
  return widths
end

-- name table: pick out PostScript name (id 6) and full name (id 4),
-- preferring Microsoft Unicode (platformID 3, encodingID 1) which
-- stores UTF-16BE, then Mac Roman (platformID 1, encodingID 0) for
-- legacy fonts. Decoded to plain Lua strings; high-BMP codepoints
-- become "?" but that's fine for ASCII-only PS names.
local function decode_name_record(data, storage_off, plat, enc, str_off, length)
  local raw = sub(data, storage_off + str_off, storage_off + str_off + length - 1)
  if plat == 3 or (plat == 0) then
    -- UTF-16BE -> Lua string (best-effort BMP-to-ASCII)
    local out = {}
    for i = 1, #raw, 2 do
      local hi = byte(raw, i) or 0
      local lo = byte(raw, i + 1) or 0
      local cp = hi * 256 + lo
      if cp < 128 then
        out[#out + 1] = string.char(cp)
      else
        out[#out + 1] = "?"
      end
    end
    return table.concat(out)
  elseif plat == 1 and enc == 0 then
    return raw -- Mac Roman: treat as ASCII passthrough
  end
  return raw
end

local function parse_name(data, t)
  local o = t.offset
  local count = u16(data, o + 2)
  local storage = u16(data, o + 4)
  local storage_off = o + storage
  -- Records, in order: track best match per nameID; prefer Microsoft
  -- (platformID 3) over Mac (platformID 1).
  local best = {}
  for i = 0, count - 1 do
    local r = o + 6 + i * 12
    local plat = u16(data, r)
    local enc = u16(data, r + 2)
    -- local lang = u16(data, r + 4)  -- unused
    local name_id = u16(data, r + 6)
    local length = u16(data, r + 8)
    local str_off = u16(data, r + 10)
    -- Priority: Microsoft Unicode BMP (3,1) > Apple Unicode (0,*) > Mac Roman (1,0).
    local prio
    if plat == 3 and enc == 1 then
      prio = 3
    elseif plat == 0 then
      prio = 2
    elseif plat == 1 and enc == 0 then
      prio = 1
    end
    if prio and (best[name_id] == nil or best[name_id].prio < prio) then
      local decoded = decode_name_record(data, storage_off, plat, enc, str_off, length)
      best[name_id] = { prio = prio, value = decoded }
    end
  end
  local function get(id)
    return best[id] and best[id].value or nil
  end
  return {
    postscript_name = get(6),
    full_name = get(4),
    family_name = get(1),
  }
end

-- OS/2 table (optional). v0 is 78 bytes; later versions add fields.
-- Just read what we need (within v0).
local function parse_os2(data, t)
  if not t then
    return nil
  end
  local o = t.offset
  local version = u16(data, o)
  local res = {
    version = version,
    fs_type = u16(data, o + 8),
    typo_ascender = s16(data, o + 68),
    typo_descender = s16(data, o + 70),
    win_ascent = u16(data, o + 74),
    win_descent = u16(data, o + 76),
  }
  -- sxHeight / sCapHeight only present in version >= 2 (offsets 86 / 88).
  if version >= 2 and t.length >= 90 then
    res.x_height = s16(data, o + 86)
    res.cap_height = s16(data, o + 88)
  end
  return res
end

local function parse_post(data, t)
  if not t then
    return nil
  end
  local o = t.offset
  return {
    italic_angle = fixed(data, o + 4),
    is_fixed_pitch = u32(data, o + 16) ~= 0,
  }
end

-- cmap format 4 parser. Returns an array of segments; gid lookup walks
-- them on demand.

local function parse_cmap_format4(data, sub_off)
  -- sub_off is the absolute (1-indexed) offset to the start of the
  -- format-4 subtable. The subtable's u16 at sub_off must be 4.
  local format = u16(data, sub_off)
  if format ~= 4 then
    return nil, ("cmap subtable format %d (expected 4)"):format(format)
  end
  local length = u16(data, sub_off + 2)
  -- seg_count_x2 is segCount*2; segCount is the number of segments.
  local seg_count_x2 = u16(data, sub_off + 6)
  local seg_count = seg_count_x2 / 2

  -- Arrays in the format-4 subtable, in order:
  --   end_code[segCount]               at +14
  --   reservedPad (u16)
  --   start_code[segCount]
  --   id_delta[segCount]   (s16)
  --   id_range_offset[segCount]
  --   glyph_id_array[]                 remainder
  local end_off = sub_off + 14
  local start_off = end_off + seg_count_x2 + 2 -- skip reservedPad
  local delta_off = start_off + seg_count_x2
  local range_off = delta_off + seg_count_x2
  local glyph_off = range_off + seg_count_x2

  local segments = {}
  for i = 0, seg_count - 1 do
    local end_code = u16(data, end_off + i * 2)
    local start_code = u16(data, start_off + i * 2)
    local id_delta = s16(data, delta_off + i * 2)
    local id_range_offset = u16(data, range_off + i * 2)
    segments[i + 1] = {
      start_code = start_code,
      end_code = end_code,
      id_delta = id_delta,
      id_range_offset = id_range_offset,
      -- For the spec's offset trick (id_range_offset != 0), the glyph
      -- id is computed relative to the id_range_offset field itself.
      -- Remember the absolute byte offset of THIS segment's range entry.
      range_entry_off = range_off + i * 2,
    }
  end

  return {
    format = 4,
    seg_count = seg_count,
    segments = segments,
    -- Whole-subtable bounds for glyph_id_array bounds checks.
    sub_off = sub_off,
    length = length,
    glyph_array_off = glyph_off,
  }
end

-- cmap container: pick the best subtable (Microsoft Unicode BMP /
-- Apple Unicode 2.0 BMP / Apple Unicode default) and parse it. Returns
-- a cmap object that exposes :gid(cp) or nil + err.
local function parse_cmap(data, t)
  local o = t.offset
  local num_subtables = u16(data, o + 2)
  local candidates = {}
  for i = 0, num_subtables - 1 do
    local r = o + 4 + i * 8
    local plat = u16(data, r)
    local enc = u16(data, r + 2)
    local sub_off = o + u32(data, r + 4)
    candidates[#candidates + 1] = { plat = plat, enc = enc, sub_off = sub_off }
  end

  -- Priority order: Microsoft Unicode BMP (3,1) > Apple Unicode BMP (0,3)
  -- > Apple Unicode 1.0 (0,0). PlatformID 3 enc 0 (symbol) is also
  -- accepted as a last resort.
  local function prio(c)
    if c.plat == 3 and c.enc == 1 then
      return 4
    end
    if c.plat == 0 and c.enc == 3 then
      return 3
    end
    if c.plat == 0 then
      return 2
    end
    if c.plat == 3 and c.enc == 0 then
      return 1
    end
    return 0
  end
  table.sort(candidates, function(a, b)
    return prio(a) > prio(b)
  end)

  for _, c in ipairs(candidates) do
    if prio(c) > 0 then
      local format = u16(data, c.sub_off)
      if format == 4 then
        local parsed, err = parse_cmap_format4(data, c.sub_off)
        if parsed then
          return parsed
        end
        -- Try next candidate.
        _ = err
      end
    end
  end
  return nil, "no usable cmap subtable (format 4 + Unicode BMP) found"
end

-- Look up a codepoint in a parsed format-4 cmap. Returns 0 for misses
-- (PDF's .notdef glyph).
local function cmap4_gid(cmap, data, cp)
  if cp < 0 or cp > 0xFFFF then
    return 0
  end
  -- Linear scan: segCount is typically ~100 segments; even a 500-segment
  -- font finishes in microseconds. Binary search would be nicer but
  -- isn't required for MVP. The segments are sorted by end_code, so
  -- we can short-circuit when end_code > cp and start_code > cp.
  for i = 1, cmap.seg_count do
    local seg = cmap.segments[i]
    if cp <= seg.end_code then
      if cp < seg.start_code then
        return 0
      end
      if seg.id_range_offset == 0 then
        local gid = (cp + seg.id_delta) % 65536
        return gid
      end
      -- Spec: glyphId = *(idRangeOffset[i]/2 + (c - startCode) + &idRangeOffset[i])
      local lookup_off = seg.range_entry_off + seg.id_range_offset + (cp - seg.start_code) * 2
      if lookup_off < cmap.sub_off + cmap.length then
        local raw = u16(data, lookup_off)
        if raw == 0 then
          return 0
        end
        return (raw + seg.id_delta) % 65536
      end
      return 0
    end
  end
  return 0
end

-- Font object.

local Font = {}
Font.__index = Font

function M.load(path)
  local data, err = read_all(path)
  if not data then
    return nil, err
  end
  local tables, terr = parse_table_directory(data)
  if not tables then
    return nil, terr
  end
  local required = { "head", "hhea", "hmtx", "maxp", "cmap", "name" }
  for _, tag in ipairs(required) do
    if not tables[tag] then
      return nil, ("missing required TTF table: %s"):format(tag)
    end
  end

  local head = parse_head(data, tables.head)
  local hhea = parse_hhea(data, tables.hhea)
  local maxp = parse_maxp(data, tables.maxp)
  local hmtx = parse_hmtx(data, tables.hmtx, hhea.num_h_metrics, maxp.num_glyphs)
  local name = parse_name(data, tables.name)
  local cmap, cerr = parse_cmap(data, tables.cmap)
  if not cmap then
    return nil, cerr
  end
  local os2 = parse_os2(data, tables["OS/2"])
  local post = parse_post(data, tables.post)

  local ps_name = name.postscript_name or name.full_name or name.family_name or "Embedded"
  -- /BaseFont in PDF can't contain spaces or several other chars; the
  -- name table's PostScript name (id 6) is already conformant, but if
  -- we fell back to full_name it might have spaces -- strip them.
  ps_name = ps_name:gsub("[%s%(%)<>%[%]%{%}/%%]", "")
  if ps_name == "" then
    ps_name = "Embedded"
  end

  return setmetatable({
    data = data,
    tables = tables,
    head = head,
    hhea = hhea,
    maxp = maxp,
    hmtx_widths = hmtx,
    cmap = cmap,
    name = name,
    os2 = os2,
    post = post,
    postscript_name = ps_name,
    full_name = name.full_name or ps_name,
    family_name = name.family_name or ps_name,
  }, Font)
end

function Font:gid(cp)
  return cmap4_gid(self.cmap, self.data, cp)
end

-- Convert a font-units value to 1/1000-of-em (PDF user-space convention
-- for /Widths in CIDFontType2). Round to nearest integer.
function Font:_to_pdf_units(font_units)
  local upem = self.head.units_per_em
  if upem == 0 then
    upem = 1000 -- defensive; pathological font
  end
  return math.floor(font_units * 1000 / upem + 0.5)
end

function Font:width(gid)
  local raw = self.hmtx_widths[gid] or self.hmtx_widths[0] or 0
  return self:_to_pdf_units(raw)
end

-- Embedding.

-- Build the W array for the CIDFontType2 dict. PDF 1.7 9.7.4.3 lets us
-- group widths either as `c [w1 w2 ...]` or `c1 c2 w`. We use the
-- former (one bracket per contiguous run of differing widths). To keep
-- output small without complex grouping, just emit all numGlyphs
-- widths in a single big bracketed run starting at CID 0. This is
-- valid: `0 [ w0 w1 w2 ... ]`.
local function build_w_array(font)
  local widths = { 0, writer.array({}) }
  local arr = widths[2]
  for i = 0, font.maxp.num_glyphs - 1 do
    arr[#arr + 1] = font:width(i)
  end
  return writer.array(widths)
end

-- Walk every codepoint exposed by the cmap (BMP only, format 4) and
-- emit a list of { cp, gid } pairs. Used for the ToUnicode CMap.
local function collect_cmap_pairs(font)
  local pairs_list = {}
  local data = font.data
  local cmap = font.cmap
  for i = 1, cmap.seg_count do
    local seg = cmap.segments[i]
    -- The last segment is sentinel (start=end=0xFFFF, idDelta=1).
    if seg.start_code == 0xFFFF and seg.end_code == 0xFFFF then
      -- skip
    else
      for cp = seg.start_code, seg.end_code do
        if cp <= 0xFFFF then
          local gid = cmap4_gid(cmap, data, cp)
          if gid ~= 0 then
            pairs_list[#pairs_list + 1] = { cp = cp, gid = gid }
          end
        end
      end
    end
  end
  return pairs_list
end

-- Build the ToUnicode CMap stream payload. Per PDF 1.7 9.10.3, /CMap
-- payload is PostScript-flavoured. Bundle bfchar entries in groups of
-- 100 (the spec limit per begin/end block) so any size of font fits.
local function build_tounicode(font)
  local cmap_pairs = collect_cmap_pairs(font)
  local out = {}
  out[#out + 1] = "/CIDInit /ProcSet findresource begin"
  out[#out + 1] = "12 dict begin"
  out[#out + 1] = "begincmap"
  out[#out + 1] = "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def"
  out[#out + 1] = "/CMapName /Adobe-Identity-UCS def"
  out[#out + 1] = "/CMapType 2 def"
  out[#out + 1] = "1 begincodespacerange"
  out[#out + 1] = "<0000> <FFFF>"
  out[#out + 1] = "endcodespacerange"

  local total = #cmap_pairs
  local i = 1
  while i <= total do
    local chunk = math.min(100, total - i + 1)
    out[#out + 1] = string.format("%d beginbfchar", chunk)
    for j = i, i + chunk - 1 do
      local p = cmap_pairs[j]
      out[#out + 1] = string.format("<%04X> <%04X>", p.gid, p.cp)
    end
    out[#out + 1] = "endbfchar"
    i = i + chunk
  end

  out[#out + 1] = "endcmap"
  out[#out + 1] = "CMapName currentdict /CMap defineresource pop"
  out[#out + 1] = "end"
  out[#out + 1] = "end"
  return table.concat(out, "\n")
end

-- FontDescriptor /Flags: bit 3 (Symbolic) is the safe default for an
-- embedded TTF that may contain arbitrary glyphs. Per PDF 1.7 9.8.2,
-- flag values are 1-indexed bit numbers, so bit 3 = value 4.
local function compute_flags(font)
  local flags = 4 -- Symbolic
  if font.post and font.post.is_fixed_pitch then
    flags = flags + 1 -- FixedPitch (bit 1)
  end
  if font.post and font.post.italic_angle ~= 0 then
    flags = flags + 64 -- Italic (bit 7)
  end
  return flags
end

function Font:embed(w)
  local ps = self.postscript_name

  -- Convert font-unit metrics to 1/1000-of-em PDF user space.
  local function pdf(v)
    return self:_to_pdf_units(v)
  end

  local ascent, descent, cap_height
  if self.os2 then
    -- Prefer typo metrics; fall back to win metrics; finally hhea.
    ascent = self.os2.typo_ascender ~= 0 and self.os2.typo_ascender or self.os2.win_ascent
    descent = self.os2.typo_descender ~= 0 and self.os2.typo_descender or -self.os2.win_descent
    cap_height = self.os2.cap_height or ascent
  else
    ascent = self.hhea.ascent
    descent = self.hhea.descent
    cap_height = ascent
  end

  local italic_angle = self.post and self.post.italic_angle or 0

  -- FontFile2 stream (the raw TTF bytes). /Length1 is the unfiltered
  -- (raw) length per PDF 1.7 9.9 -- since we don't compress, /Length1
  -- == /Length, but the spec requires /Length1 to be present anyway.
  local fontfile_ref = w:add(writer.stream(self.data, { Length1 = #self.data }))

  local font_descriptor_ref = w:add({
    Type = "/FontDescriptor",
    FontName = "/" .. ps,
    Flags = compute_flags(self),
    FontBBox = writer.array({
      pdf(self.head.x_min),
      pdf(self.head.y_min),
      pdf(self.head.x_max),
      pdf(self.head.y_max),
    }),
    ItalicAngle = math.floor(italic_angle + 0.5),
    Ascent = pdf(ascent),
    Descent = pdf(descent),
    CapHeight = pdf(cap_height),
    StemV = 80, -- arbitrary; PDF readers don't really care for embedded fonts
    FontFile2 = fontfile_ref,
  })

  local cidfont_ref = w:add({
    Type = "/Font",
    Subtype = "/CIDFontType2",
    BaseFont = "/" .. ps,
    CIDSystemInfo = writer.dict({
      Registry = "Adobe",
      Ordering = "Identity",
      Supplement = 0,
    }),
    FontDescriptor = font_descriptor_ref,
    W = build_w_array(self),
    CIDToGIDMap = "/Identity",
  })

  local tounicode_ref = w:add(writer.stream(build_tounicode(self), {}))

  local type0_ref = w:add({
    Type = "/Font",
    Subtype = "/Type0",
    BaseFont = "/" .. ps,
    Encoding = "/Identity-H",
    DescendantFonts = writer.array({ cidfont_ref }),
    ToUnicode = tounicode_ref,
  })

  -- Side-band: stash the leaf refs in case callers want to inspect them
  -- for tests / debugging. Not part of the documented surface.
  self._refs = {
    type0 = type0_ref,
    cidfont = cidfont_ref,
    descriptor = font_descriptor_ref,
    fontfile = fontfile_ref,
    tounicode = tounicode_ref,
  }
  return type0_ref
end

M.Font = Font

return M
