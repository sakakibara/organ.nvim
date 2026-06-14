-- Document AST -> HTML5 string.
--
-- Companion to from_org.lua.  Emits a complete HTML5 document
-- (DOCTYPE + <html>/<head>/<body>) wrapping a body rendered from
-- the AST.  Inline math regions are passed through verbatim so a
-- client-side MathJax build can typeset them; the loader script is
-- emitted only when the document uses math (or the caller forces it).

local M = {}

local DEFAULT_STYLE = [[
body { font-family: -apple-system, system-ui, sans-serif; max-width: 720px; margin: 2em auto; padding: 0 1em; line-height: 1.6; color: #222; }
pre { background: #f4f4f4; padding: 0.7em; overflow-x: auto; border-radius: 4px; }
code { background: #f4f4f4; padding: 0.1em 0.3em; border-radius: 3px; }
pre code { background: transparent; padding: 0; }
table { border-collapse: collapse; margin: 1em 0; }
th, td { border: 1px solid #ccc; padding: 0.4em 0.7em; }
th { background: #f4f4f4; }
hr { border: 0; border-top: 1px solid #ccc; margin: 2em 0; }
a { color: #0366d6; }
]]

local function html_escape(s)
  if not s then
    return ""
  end
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  return s
end

-- Module-local flag flipped on whenever a math region is encountered.
-- M.render checks this when assembling the document head so MathJax
-- loads only when needed. Reset at the start of every render call.
local _math_used = false

local emit_inline
local emit_block

function emit_inline(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = html_escape(n.text or "")
    elseif n.kind == "emphasis" then
      local inner = emit_inline(n.content)
      local s = n.style
      if s == "bold" then
        out[#out + 1] = "<strong>" .. inner .. "</strong>"
      elseif s == "italic" then
        out[#out + 1] = "<em>" .. inner .. "</em>"
      elseif s == "underline" then
        out[#out + 1] = "<u>" .. inner .. "</u>"
      elseif s == "strike" then
        out[#out + 1] = "<del>" .. inner .. "</del>"
      elseif s == "verbatim" or s == "code" then
        out[#out + 1] = "<code>" .. inner .. "</code>"
      else
        out[#out + 1] = inner
      end
    elseif n.kind == "link" then
      local target = html_escape(n.target or "")
      if n.description and #n.description > 0 then
        out[#out + 1] = '<a href="' .. target .. '">' .. emit_inline(n.description) .. "</a>"
      else
        out[#out + 1] = '<a href="' .. target .. '">' .. target .. "</a>"
      end
    elseif n.kind == "image" then
      local target = html_escape(n.target or "")
      local alt_src = n.alt and n.alt ~= "" and n.alt or (n.target or "")
      out[#out + 1] = '<img src="' .. target .. '" alt="' .. html_escape(alt_src) .. '">'
    elseif n.kind == "footnote_ref" then
      local label = html_escape(n.label or "")
      out[#out + 1] = '<sup><a href="#fn-' .. label .. '">[' .. label .. "]</a></sup>"
    elseif n.kind == "math" then
      _math_used = true
      if n.display then
        out[#out + 1] = "\\[" .. (n.body or "") .. "\\]"
      else
        out[#out + 1] = "$" .. (n.body or "") .. "$"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "<br>"
    elseif n.kind == "raw_inline" then
      out[#out + 1] = html_escape(n.text or "")
    end
  end
  local s = table.concat(out)
  local ok, cite = pcall(require, "organ.cite")
  if ok and type(cite.replace_in) == "function" then
    s = cite.replace_in(s, "html")
  end
  return s
end

local function emit_headline(node, out)
  local level = math.min(6, math.max(1, node.level or 1))
  local title = emit_inline(node.title or {})
  out[#out + 1] = "<h" .. level .. ">" .. title .. "</h" .. level .. ">"
  for _, c in ipairs(node.children or {}) do
    emit_block(c, out)
  end
end

local function emit_paragraph(node, out)
  out[#out + 1] = "<p>" .. emit_inline(node.inline or {}) .. "</p>"
end

local function emit_list(node, out)
  local tag = node.ordered and "ol" or "ul"
  out[#out + 1] = "<" .. tag .. ">"
  for _, item in ipairs(node.items or {}) do
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = '<input type="checkbox" disabled> '
    elseif item.checkbox == "done" then
      checkbox = '<input type="checkbox" checked disabled> '
    elseif item.checkbox == "part" then
      checkbox = '<input type="checkbox" disabled> '
    end
    -- Compose the <li> content: first paragraph inline + any nested
    -- lists + any continuation paragraphs.
    local pieces = {}
    local first_para_done = false
    for _, b in ipairs(item.content or {}) do
      if b.kind == "paragraph" then
        if not first_para_done then
          pieces[#pieces + 1] = checkbox .. emit_inline(b.inline)
          first_para_done = true
        else
          pieces[#pieces + 1] = emit_inline(b.inline)
        end
      elseif b.kind == "list" then
        local sub_out = {}
        emit_list(b, sub_out)
        pieces[#pieces + 1] = table.concat(sub_out, "\n")
      end
    end
    if not first_para_done and checkbox ~= "" then
      -- Edge case: item has no paragraph but has a checkbox.
      pieces[#pieces + 1] = checkbox
    end
    out[#out + 1] = "<li>" .. table.concat(pieces, "\n") .. "</li>"
  end
  out[#out + 1] = "</" .. tag .. ">"
end

local function emit_code_block(node, out)
  local body = html_escape(node.body or "")
  local lang = node.language
  if lang and lang ~= "" then
    out[#out + 1] = '<pre><code class="language-'
      .. html_escape(lang)
      .. '">'
      .. body
      .. "</code></pre>"
  else
    out[#out + 1] = "<pre><code>" .. body .. "</code></pre>"
  end
end

local function emit_org_block(node, out)
  local style = node.style
  if style == "verse" or style == "example" then
    out[#out + 1] = "<pre>" .. html_escape(node.body or "") .. "</pre>"
  elseif style == "quote" then
    out[#out + 1] = "<blockquote>"
    for _, b in ipairs(node.content or {}) do
      emit_block(b, out)
    end
    out[#out + 1] = "</blockquote>"
  end
  -- export / unknown: silently drop
end

local function emit_table(node, out)
  local rows = node.rows or {}
  if #rows == 0 then
    return
  end
  local ncols = 0
  for _, r in ipairs(rows) do
    if not r.sep and r.cells then
      if #r.cells > ncols then
        ncols = #r.cells
      end
    end
  end
  if ncols == 0 then
    return
  end

  -- Find first separator: rows before it are thead, rows after are tbody.
  local first_sep
  for i, r in ipairs(rows) do
    if r.sep then
      first_sep = i
      break
    end
  end

  local function emit_row(row, cell_tag, out_buf)
    local parts = {}
    for c = 1, ncols do
      parts[#parts + 1] = "<"
        .. cell_tag
        .. ">"
        .. emit_inline(row.cells[c] or {})
        .. "</"
        .. cell_tag
        .. ">"
    end
    out_buf[#out_buf + 1] = "<tr>" .. table.concat(parts) .. "</tr>"
  end

  out[#out + 1] = "<table>"
  if first_sep and first_sep > 1 then
    out[#out + 1] = "<thead>"
    for i = 1, first_sep - 1 do
      if not rows[i].sep then
        emit_row(rows[i], "th", out)
      end
    end
    out[#out + 1] = "</thead>"
  end
  out[#out + 1] = "<tbody>"
  local body_start = first_sep and first_sep + 1 or 1
  for i = body_start, #rows do
    if not rows[i].sep then
      emit_row(rows[i], "td", out)
    end
  end
  out[#out + 1] = "</tbody>"
  out[#out + 1] = "</table>"
end

local function emit_image_block(node, out)
  local target = html_escape(node.target or "")
  local alt = (node.alt and node.alt ~= "") and node.alt or (node.target or "")
  out[#out + 1] = '<p><img src="' .. target .. '" alt="' .. html_escape(alt) .. '"></p>'
end

local function emit_rule(_, out)
  out[#out + 1] = "<hr>"
end

local function emit_footnote_definition(node, out)
  local label = node.label or ""
  local label_esc = html_escape(label)
  local first_body = ""
  if node.content and node.content[1] and node.content[1].kind == "paragraph" then
    first_body = emit_inline(node.content[1].inline)
  end
  local pieces = {
    '<div class="footdef" id="fn-'
      .. label_esc
      .. '"><sup>['
      .. label_esc
      .. "]</sup> "
      .. first_body,
  }
  if node.content and #node.content > 1 then
    for i = 2, #node.content do
      local b = node.content[i]
      if b.kind == "paragraph" then
        pieces[#pieces + 1] = "<p>" .. emit_inline(b.inline) .. "</p>"
      end
    end
  end
  pieces[#pieces + 1] = "</div>"
  out[#out + 1] = table.concat(pieces)
end

function emit_block(node, out)
  if not node or not node.kind then
    return
  end
  local kind = node.kind
  if kind == "document" then
    for _, c in ipairs(node.children or {}) do
      emit_block(c, out)
    end
  elseif kind == "headline" then
    emit_headline(node, out)
  elseif kind == "paragraph" then
    emit_paragraph(node, out)
  elseif kind == "list" then
    emit_list(node, out)
  elseif kind == "code_block" then
    emit_code_block(node, out)
  elseif kind == "block" then
    emit_org_block(node, out)
  elseif kind == "table" then
    emit_table(node, out)
  elseif kind == "image" then
    emit_image_block(node, out)
  elseif kind == "rule" then
    emit_rule(node, out)
  elseif kind == "footnote_definition" then
    emit_footnote_definition(node, out)
  end
  -- directive, drawer, comment, and unknown kinds drop silently.
end

local function find_title(doc)
  if not doc or not doc.children then
    return nil
  end
  for _, c in ipairs(doc.children) do
    if c.kind == "directive" and c.name == "TITLE" then
      return c.value
    end
  end
  for _, c in ipairs(doc.children) do
    if c.kind == "headline" then
      return emit_inline(c.title or {})
    end
  end
  return nil
end

function M.render(doc, opts)
  opts = opts or {}
  _math_used = false

  -- Title resolution may set _math_used if it falls back to a headline
  -- whose title contains math; do it before assembling the head.
  local title = find_title(doc) or "Untitled"

  local body = {}
  for _, c in ipairs(doc.children or {}) do
    emit_block(c, body)
  end

  local style_block = opts.minimal_style == false and "" or "<style>" .. DEFAULT_STYLE .. "</style>"

  -- MathJax: load when the document used any math OR when opts/config
  -- explicitly forces it. Config:
  --   html = { mathjax = "cdn" | <url> | false } -- defaults to "cdn".
  local cfg_html
  do
    local ok, organ = pcall(require, "organ")
    cfg_html = (ok and organ.config and require("organ.buf_config").read(nil, "html")) or {}
  end
  local mj_opt = opts.mathjax
  if mj_opt == nil then
    mj_opt = cfg_html.mathjax
  end
  if mj_opt == nil then
    mj_opt = "cdn"
  end
  local mathjax_block = ""
  local should_load_mathjax = (_math_used or opts.force_mathjax) and mj_opt ~= false
  if should_load_mathjax then
    local mj_url = mj_opt == "cdn" and "https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"
      or tostring(mj_opt)
    mathjax_block = string.format(
      [==[<script>window.MathJax = { tex: { inlineMath: [['$','$'], ['\\(','\\)']], displayMath: [['\\[','\\]']] } };</script><script async src="%s"></script>]==],
      mj_url
    )
  end

  local out = {
    "<!DOCTYPE html>",
    '<html lang="en">',
    "<head>",
    '  <meta charset="utf-8">',
    '  <meta name="viewport" content="width=device-width, initial-scale=1">',
    "  <title>" .. html_escape(title) .. "</title>",
    "  " .. style_block,
    "  " .. mathjax_block,
    "</head>",
    "<body>",
  }
  for _, l in ipairs(body) do
    out[#out + 1] = l
  end
  out[#out + 1] = "</body>"
  out[#out + 1] = "</html>"
  return table.concat(out, "\n") .. "\n"
end

-- Expose internals for tests.
M._emit_inline = emit_inline
M._emit_block = emit_block

return M
