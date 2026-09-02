-- Greedy line-break + pagination over a font from `organ.pdf.font`.
--
-- Input is a stream of typeset calls (paragraph, heading, code block,
-- blank). Output is a tree of pages -> lines -> positioned text runs,
-- ready for a content-stream emitter to translate into
-- `BT /F1 sz Tf x y Td (text) Tj ET` sequences.
--
-- Greedy word wrap only (no Knuth-Plass). Words wrap whole; a word
-- wider than the column by itself (unspaced CJK prose, long URLs) is
-- broken between codepoints, never hyphenated.

local M = {}

-- UTF-8 codepoint iterator. Returns successive codepoints from a Lua
-- string together with the byte index of each codepoint's last byte.
-- Continuation bytes encountered alone fall through as raw byte
-- values (latin-1) -- defensive against malformed input.

local function utf8_codepoints(s)
  local i, n = 1, #s
  return function()
    if i > n then
      return nil
    end
    local b = s:byte(i)
    local cp, w
    if b < 0x80 then
      cp, w = b, 1
    elseif b < 0xC0 then
      cp, w = b, 1
    elseif b < 0xE0 then
      cp = (b - 0xC0) * 64 + ((s:byte(i + 1) or 0x80) - 0x80)
      w = 2
    elseif b < 0xF0 then
      cp = (b - 0xE0) * 4096
        + ((s:byte(i + 1) or 0x80) - 0x80) * 64
        + ((s:byte(i + 2) or 0x80) - 0x80)
      w = 3
    else
      cp = (b - 0xF0) * 262144
        + ((s:byte(i + 1) or 0x80) - 0x80) * 4096
        + ((s:byte(i + 2) or 0x80) - 0x80) * 64
        + ((s:byte(i + 3) or 0x80) - 0x80)
      w = 4
    end
    i = i + w
    return cp, i - 1
  end
end

-- Width of a string in PDF user-space points at the given font/size.
-- font:width returns 1/1000-em units; multiply by size/1000 to get
-- points.
local function measure(font, size, s)
  local total = 0
  for cp in utf8_codepoints(s) do
    local gid = font:gid(cp)
    total = total + font:width(gid)
  end
  return total * size / 1000
end

-- Longest prefix of `s` made of whole codepoints that is no wider than
-- `room`; at least one codepoint when `force`. Returns the prefix, its
-- width, and the remainder.
local function take_prefix(font, size, s, room, force)
  local width, stop = 0, 0
  for cp, last in utf8_codepoints(s) do
    local w = font:width(font:gid(cp)) * size / 1000
    if width + w > room and not (force and stop == 0) then
      break
    end
    width = width + w
    stop = last
  end
  return s:sub(1, stop), width, s:sub(stop + 1)
end

-- Split an input string on ASCII whitespace (space, tab, newline, CR).
-- Empty splits between runs of whitespace are dropped.
local function split_words(s)
  local out = {}
  for word in s:gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

-- Layout state machine.

local Layout = {}
Layout.__index = Layout

-- Heading level -> font size in points. L1 dominates; everything past
-- the documented range falls back to the default body size.
local HEADING_SIZES = {
  [1] = 18,
  [2] = 16,
  [3] = 14,
  [4] = 12,
}

function M.new(opts)
  opts = opts or {}
  assert(opts.default_font, "layout.new: default_font is required")
  local self = setmetatable({
    page_width = opts.page_width or 612,
    page_height = opts.page_height or 792,
    margin_left = opts.margin_left or 72,
    margin_right = opts.margin_right or 72,
    margin_top = opts.margin_top or 72,
    margin_bottom = opts.margin_bottom or 72,
    default_font = opts.default_font,
    default_font_size = opts.default_font_size or 11,
    line_gap_factor = opts.line_gap_factor or 1.2,
    pages = {},
    current = nil, -- in-progress page, created by the first line on it
    cursor_y = nil, -- baseline of the last line or spacing on that page
  }, Layout)
  return self
end

-- Right edge of the text column.
function Layout:_content_width()
  return self.page_width - self.margin_left - self.margin_right
end

-- Y-coordinate of the first baseline on a page given `font_size`.
function Layout:_top_baseline(font_size)
  return self.page_height - self.margin_top - font_size
end

function Layout:_start_page()
  self.current = { lines = {} }
  self.pages[#self.pages + 1] = self.current
end

-- Emit one line at the current cursor. If we're at the start of a page,
-- the baseline is `page_height - margin_top - font_size`; otherwise it
-- advances by `font_size * line_gap_factor` from the previous baseline.
-- Pages are created here, never by spacing alone, so trailing spacing
-- cannot leave an empty page behind.
function Layout:_emit_line(line_text, font, font_size, x)
  local line_gap = font_size * self.line_gap_factor
  if self.cursor_y == nil then
    self.cursor_y = self:_top_baseline(font_size)
  else
    self.cursor_y = self.cursor_y - line_gap
  end
  -- If the new baseline would dip below the bottom margin, start a new
  -- page and place this line at the top there.
  if self.cursor_y < self.margin_bottom then
    self.current = nil
    self.cursor_y = self:_top_baseline(font_size)
  end
  if not self.current then
    self:_start_page()
  end
  table.insert(self.current.lines, {
    x = x or self.margin_left,
    y = self.cursor_y,
    font = font,
    font_size = font_size,
    text = line_text,
  })
end

-- Advance the cursor by one line height WITHOUT producing a line entry.
-- Used for blank lines and pre/post spacing around headings / code.
function Layout:_advance(font_size, factor)
  factor = factor or self.line_gap_factor
  if self.cursor_y == nil then
    -- Equivalent to placing an invisible first baseline at the top
    -- and then skipping.
    self.cursor_y = self:_top_baseline(font_size)
  end
  self.cursor_y = self.cursor_y - font_size * factor
  if self.cursor_y < self.margin_bottom then
    -- Roll to the next page; the next emitted line creates it.
    self.current = nil
    self.cursor_y = nil
  end
end

-- Public surface.

-- `style.indent` (points) shifts every line of the paragraph right and
-- narrows its column by the same amount.
function Layout:add_paragraph(text, style)
  style = style or {}
  local font = style.font or self.default_font
  local font_size = style.font_size or self.default_font_size
  local indent = style.indent or 0
  if not text or text == "" then
    return self.pages
  end
  local words = split_words(text)
  if #words == 0 then
    return self.pages
  end

  local x = self.margin_left + indent
  local max_width = self:_content_width() - indent
  local space_width = measure(font, font_size, " ")

  local line_words = {}
  local line_width = 0
  local function commit()
    if #line_words > 0 then
      self:_emit_line(table.concat(line_words, " "), font, font_size, x)
      line_words = {}
      line_width = 0
    end
  end
  local function append(w, ww)
    if #line_words == 0 then
      line_width = ww
    else
      line_width = line_width + space_width + ww
    end
    line_words[#line_words + 1] = w
  end
  local function room()
    return max_width - line_width - (#line_words > 0 and space_width or 0)
  end

  for _, w in ipairs(words) do
    local ww = measure(font, font_size, w)
    if ww <= room() then
      append(w, ww)
    elseif ww <= max_width then
      commit()
      append(w, ww)
    else
      local rest = w
      while rest ~= "" do
        local piece, pw
        piece, pw, rest = take_prefix(font, font_size, rest, room(), #line_words == 0)
        if piece == "" then
          commit()
        else
          append(piece, pw)
          if rest ~= "" then
            commit()
          end
        end
      end
    end
  end
  commit()
  return self.pages
end

-- Paragraph break: skip a line at the current default size.
function Layout:add_blank(style)
  style = style or {}
  local font_size = style.font_size or self.default_font_size
  self:_advance(font_size)
end

function Layout:add_heading(text, opts)
  opts = opts or {}
  local level = opts.level or 1
  local font_size = opts.font_size or HEADING_SIZES[level] or self.default_font_size
  local font = opts.font or self.default_font

  -- Pre-spacing.
  self:_advance(font_size, 0.5)
  self:add_paragraph(text, { font = font, font_size = font_size })
  -- Post-spacing.
  self:_advance(font_size, 0.5)
end

function Layout:add_code_block(lines, opts)
  opts = opts or {}
  local font = opts.font or self.default_font
  local font_size = opts.font_size or self.default_font_size

  self:_advance(font_size, 0.3)
  for _, line in ipairs(lines) do
    -- Empty source lines should still advance the cursor. Emit a line
    -- entry with empty text so the renderer can faithfully reproduce
    -- the spacing -- this matches how a code block's blank rows are
    -- semantically real lines, not paragraph breaks.
    self:_emit_line(line, font, font_size)
  end
  self:_advance(font_size, 0.3)
end

-- Finalize and hand back the laid-out tree. After calling :finish the
-- state should not be re-used.
function Layout:finish()
  return { pages = self.pages }
end

-- Exposed helpers for the test suite.

M._measure = measure
M.Layout = Layout
M.HEADING_SIZES = HEADING_SIZES

return M
