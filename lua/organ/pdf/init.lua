-- Organ AST -> PDF bytes. Wires the lower layers (writer / document /
-- font / font_search / layout) together: load fonts, walk the AST,
-- drive the layout state machine, then translate the resulting page
-- tree into PDF content streams attached to real page objects.
--
-- AST kinds covered for MVP: headline, paragraph, code_block, block
-- (verse/example/quote), list (flattened with markers), document root.
-- Other kinds (directive, drawer, image, rule, table, footnote_def,
-- comment) drop silently; they belong to a later increment.
--
-- Glyphs are emitted as 16-bit CIDs because the embedded Type0 font
-- uses /Encoding /Identity-H (see organ.pdf.font). Text positioning
-- uses absolute /Tm rather than relative /Td so we don't have to
-- track previous-baseline state across lines.

local document_mod = require("organ.pdf.document")
local font_mod = require("organ.pdf.font")
local font_search = require("organ.pdf.font_search")
local layout_mod = require("organ.pdf.layout")
local writer = require("organ.pdf.writer")

local M = {}

-- Inline flattening.

-- Strip inline markup to plain text. Emphasis unwraps to its content;
-- links keep their description (with target in parens if both differ);
-- math passes through with bracket markers since v1 doesn't typeset it.
-- Image / footnote_ref / linebreak: dropped for MVP.
local function emit_inline(nodes)
  if not nodes then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "emphasis" then
      out[#out + 1] = emit_inline(n.content)
    elseif n.kind == "link" then
      local desc = n.description and emit_inline(n.description) or ""
      if desc ~= "" then
        out[#out + 1] = desc .. " (" .. (n.target or "") .. ")"
      else
        out[#out + 1] = n.target or ""
      end
    elseif n.kind == "math" then
      out[#out + 1] = "<" .. (n.body or "") .. ">"
    end
  end
  return table.concat(out)
end

-- Body splitter for code-block / verse / example: preserve every source
-- line including trailing empties. `gmatch("[^\n]*")` is unreliable for
-- empty trailing lines; do it by hand.
local function split_lines(s)
  if not s or s == "" then
    return {}
  end
  local out = {}
  local start = 1
  while true do
    local nl = s:find("\n", start, true)
    if not nl then
      out[#out + 1] = s:sub(start)
      break
    end
    out[#out + 1] = s:sub(start, nl - 1)
    start = nl + 1
  end
  return out
end

-- AST dispatch.

local render_block

local function render_paragraph(node, ctx)
  ctx.layout:add_paragraph(emit_inline(node.inline))
end

local function render_headline(node, ctx)
  local level = node.level or 1
  ctx.layout:add_heading(emit_inline(node.title), { level = level })
  for _, child in ipairs(node.children or {}) do
    render_block(child, ctx)
  end
end

local function render_code_block(node, ctx)
  ctx.layout:add_code_block(split_lines(node.body), { font = ctx.mono_font })
end

local function render_block_node(node, ctx)
  local style = node.style
  if style == "verse" or style == "example" then
    ctx.layout:add_code_block(split_lines(node.body or ""), { font = ctx.mono_font })
  elseif style == "quote" then
    -- Treat quote content as inline blocks; no indent yet (future work).
    if node.content then
      for _, child in ipairs(node.content) do
        render_block(child, ctx)
      end
    elseif node.body then
      ctx.layout:add_paragraph(node.body)
    end
  end
  -- Unknown block styles (center, export, ...): drop silently.
end

-- Render a list as one paragraph per item, prefixed with a marker.
-- Nested lists are walked recursively. Checkbox state surfaces as a
-- bracketed marker before the bullet.
local function render_list(node, ctx, depth)
  depth = depth or 0
  local indent = string.rep("  ", depth)
  for i, item in ipairs(node.items or {}) do
    local marker
    if node.ordered then
      marker = tostring(i) .. ". "
    else
      marker = "- "
    end
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = "[ ] "
    elseif item.checkbox == "done" then
      checkbox = "[X] "
    elseif item.checkbox == "part" then
      checkbox = "[-] "
    end
    -- Item content: first paragraph (if any) gets the prefix; further
    -- blocks render normally underneath.
    local first = true
    for _, child in ipairs(item.content or {}) do
      if first and child.kind == "paragraph" then
        ctx.layout:add_paragraph(indent .. marker .. checkbox .. emit_inline(child.inline))
        first = false
      elseif first and (checkbox ~= "" or marker ~= "") then
        -- Empty-bodied item still deserves a visible bullet.
        ctx.layout:add_paragraph(indent .. marker .. checkbox)
        first = false
        render_block(child, ctx)
      elseif child.kind == "list" then
        render_list(child, ctx, depth + 1)
      else
        render_block(child, ctx)
      end
    end
    if first then
      -- The item had no content at all.
      ctx.layout:add_paragraph(indent .. marker .. checkbox)
    end
  end
end

render_block = function(node, ctx)
  if not node or not node.kind then
    return
  end
  local k = node.kind
  if k == "paragraph" then
    render_paragraph(node, ctx)
  elseif k == "headline" then
    render_headline(node, ctx)
  elseif k == "code_block" then
    render_code_block(node, ctx)
  elseif k == "block" then
    render_block_node(node, ctx)
  elseif k == "list" then
    render_list(node, ctx, 0)
  end
  -- All other kinds (directive, drawer, image, rule, table,
  -- footnote_definition, comment): drop silently for MVP.
end

-- Content stream emission.

-- Hex-encode a string as 16-bit big-endian CIDs by mapping each UTF-8
-- codepoint through font:gid. The output is the bracketed body for
-- a PDF hex string: "<HHHH HHHH ...>" (no spaces).
local function encode_glyphs(font, text)
  if not text or text == "" then
    return "<>"
  end
  local out = { "<" }
  local i, n = 1, #text
  while i <= n do
    local b = text:byte(i)
    local cp, w
    if b < 0x80 then
      cp, w = b, 1
    elseif b < 0xC0 then
      cp, w = b, 1
    elseif b < 0xE0 then
      cp = (b - 0xC0) * 64 + ((text:byte(i + 1) or 0x80) - 0x80)
      w = 2
    elseif b < 0xF0 then
      cp = (b - 0xE0) * 4096
        + ((text:byte(i + 1) or 0x80) - 0x80) * 64
        + ((text:byte(i + 2) or 0x80) - 0x80)
      w = 3
    else
      cp = (b - 0xF0) * 262144
        + ((text:byte(i + 1) or 0x80) - 0x80) * 4096
        + ((text:byte(i + 2) or 0x80) - 0x80) * 64
        + ((text:byte(i + 3) or 0x80) - 0x80)
      w = 4
    end
    local gid = font:gid(cp) or 0
    out[#out + 1] = string.format("%04X", gid)
    i = i + w
  end
  out[#out + 1] = ">"
  return table.concat(out)
end

-- Build the operator stream for a single laid-out page. `font_names`
-- maps a font instance to its /Resources /Font key (e.g. "F1", "F2").
-- A separate Tf operator is emitted per line: trivially correct, and
-- typically smaller than tracking save/restore state for mixed runs.
local function build_content_stream(page_lines, font_names)
  local parts = {}
  for _, line in ipairs(page_lines) do
    local fname = font_names[line.font]
    if fname then
      parts[#parts + 1] = "BT"
      parts[#parts + 1] = string.format("/%s %s Tf", fname, tostring(line.font_size))
      -- Absolute text matrix: 1 0 0 1 x y Tm. Tm resets the position;
      -- no need to track previous-baseline deltas across lines.
      parts[#parts + 1] = string.format("1 0 0 1 %s %s Tm", tostring(line.x), tostring(line.y))
      parts[#parts + 1] = encode_glyphs(line.font, line.text or "") .. " Tj"
      parts[#parts + 1] = "ET"
    end
  end
  return table.concat(parts, "\n")
end

-- Top-level: AST -> PDF bytes.

-- Resolve a font: explicit `path` wins; otherwise font_search.find
-- looks one up by style.
local function load_font(path, style)
  local resolved = path
  if not resolved then
    local found, err = font_search.find({ style = style })
    if not found then
      return nil, err or ("no font found for style " .. style)
    end
    resolved = found
  end
  local font, ferr = font_mod.load(resolved)
  if not font then
    return nil, ferr
  end
  return font
end

function M.render(ast_root, opts)
  opts = opts or {}

  -- 1. Fonts.
  local regular, err = load_font(opts.font_path, "regular")
  if not regular then
    return nil, err
  end
  local mono = load_font(opts.mono_font_path, "mono")
  if not mono then
    -- A document with no code blocks works fine with only the regular
    -- font, but we always allocate a mono slot in /Resources for
    -- determinism (callers can predict resource keys). Fall back to the
    -- regular face if mono can't be found -- still produces valid PDF.
    mono = regular
  end

  -- 2. Layout.
  local L = layout_mod.new({
    page_width = opts.page_width,
    page_height = opts.page_height,
    margin_left = opts.margin_left,
    margin_right = opts.margin_right,
    margin_top = opts.margin_top,
    margin_bottom = opts.margin_bottom,
    default_font = regular,
    default_font_size = opts.default_font_size or 11,
  })

  -- 3. Walk AST. The root is expected to be a `document` node but we
  -- tolerate any node with `children`; tests sometimes pass a bare
  -- headline / paragraph at the top level.
  local ctx = { layout = L, mono_font = mono }
  if ast_root and ast_root.kind == "document" then
    for _, child in ipairs(ast_root.children or {}) do
      render_block(child, ctx)
    end
  elseif ast_root then
    render_block(ast_root, ctx)
  end

  local result = L:finish()

  -- 4. Build the PDF.
  local doc = document_mod.new()

  -- Embed both fonts up front so we always have stable resource refs.
  local regular_ref = regular:embed(doc.w)
  local mono_ref = (mono == regular) and regular_ref or mono:embed(doc.w)
  local font_names = { [regular] = "F1", [mono] = "F2" }

  -- The /Resources /Font dict carries BOTH font entries even on pages
  -- that only use one. Keeping it identical across pages means readers
  -- can cache it and tests can grep for either key without knowing
  -- which page used what.
  local function make_resources()
    local fonts = writer.dict({
      F1 = regular_ref,
      F2 = mono_ref,
    })
    return writer.dict({ Font = fonts })
  end

  local page_width = opts.page_width or 612
  local page_height = opts.page_height or 792

  if #result.pages == 0 then
    -- Empty document: emit a single blank page so the PDF is still
    -- well-formed (a /Pages tree with /Count 0 is technically valid
    -- but practically useless and trips some readers).
    local page_ref = doc:add_page({ width = page_width, height = page_height })
    doc.w:set(page_ref, {
      Type = "/Page",
      Parent = doc.pages_ref,
      MediaBox = { 0, 0, page_width, page_height },
      Resources = make_resources(),
    })
  else
    for _, page in ipairs(result.pages) do
      local page_ref = doc:add_page({ width = page_width, height = page_height })
      local stream_body = build_content_stream(page.lines, font_names)
      local content_ref = doc.w:add(writer.stream(stream_body, {}))
      doc.w:set(page_ref, {
        Type = "/Page",
        Parent = doc.pages_ref,
        MediaBox = { 0, 0, page_width, page_height },
        Resources = make_resources(),
        Contents = content_ref,
      })
    end
  end

  return doc:bytes()
end

-- Test hooks.

M._emit_inline = emit_inline
M._split_lines = split_lines
M._encode_glyphs = encode_glyphs

return M
