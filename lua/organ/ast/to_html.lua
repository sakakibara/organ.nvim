-- Document AST -> HTML5 string.
--
-- Companion to from_org.lua.  Emits a complete HTML5 document
-- (DOCTYPE + <html>/<head>/<body>) wrapping a body rendered from
-- the AST.  Inline math regions are passed through verbatim so a
-- client-side MathJax build can typeset them; the loader script is
-- emitted only when the document uses math (or the caller forces it).

local A = require("organ.ast")
local links = require("organ.ast.links")
local ENTITIES = require("organ.ast.org_entities")
local OPTIONS = require("organ.export.options")

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

local slug = links.slug

-- Resolved export options, outline counters, and the `Table N:` /
-- `Listing N:` / `Figure N:` sequence numbers ox-html assigns to
-- captioned elements.
local _o = OPTIONS.defaults()
local _secno = {}
local _ordinal = {}

-- org-export-activate-smart-quotes / org-export-special-strings, applied
-- to plain text only.  Runs after escaping so the entities it produces
-- are not escaped in turn.
local function smart_quotes(s)
  s = s:gsub("()&quot;", function(pos)
    local prev = s:sub(pos - 1, pos - 1)
    return (prev == "" or prev:match("[%s%(%[{]")) and "&ldquo;" or "&rdquo;"
  end)
  local subject = s
  return (
    s:gsub("()'", function(pos)
      return subject:sub(pos - 1, pos - 1):match("[%w]") and "&rsquo;" or "&lsquo;"
    end)
  )
end

local function plain_text(s)
  s = html_escape(s)
  if _o.with_special_strings then
    s = s:gsub("%-%-%-", "&#x2014;"):gsub("%-%-", "&#x2013;"):gsub("%.%.%.", "&#x2026;")
  end
  if _o.with_smart_quotes then
    s = smart_quotes(s)
  end
  if _o.preserve_breaks then
    s = s:gsub("\n", "<br />\n")
  end
  return s
end

-- Module-local flag flipped on whenever a math region is encountered.
-- M.render checks this when assembling the document head so MathJax
-- loads only when needed. Reset at the start of every render call.
local _math_used = false

-- Per-render link destinations and footnotes numbered by first reference.
local _index
local _fn = { numbers = {}, order = {} }

local emit_inline
local emit_block
local emit_toc_keyword
-- The document being rendered, and the headline a `#+TOC: ... local`
-- sits under while its section emits.
local _doc
local _toc_scope
local _toc_count = 0

local function affiliated(node, name)
  for _, a in ipairs(node.affiliated or {}) do
    if a.name == name then
      return a
    end
  end
end

-- `#+ATTR_HTML: :width 100 :class fancy` -> ` width="100" class="fancy"`.
local function attr_html(node)
  local a = affiliated(node, "ATTR_HTML")
  if not a then
    return ""
  end
  local out, key, vals = {}, nil, {}
  local function flush()
    if key then
      out[#out + 1] = key .. '="' .. html_escape(table.concat(vals, " ")) .. '"'
    end
  end
  for tok in (a.value or ""):gmatch("%S+") do
    local k = tok:match("^:([%w_-]+)$")
    if k then
      flush()
      key, vals = k, {}
    elseif key then
      vals[#vals + 1] = tok
    end
  end
  flush()
  return #out > 0 and (" " .. table.concat(out, " ")) or ""
end

local function name_attr(node)
  local a = affiliated(node, "NAME")
  if a and a.value ~= "" and not attr_html(node):find(' id="', 1, true) then
    return ' id="' .. html_escape(a.value) .. '"'
  end
  return ""
end

local function ordinal(kind)
  _ordinal[kind] = (_ordinal[kind] or 0) + 1
  return _ordinal[kind]
end

-- Caption markup for `kind` ("table" | "listing" | "figure"), or nil.
local function caption_parts(node, kind)
  local a = affiliated(node, "CAPTION")
  if not a then
    return nil
  end
  local text = a.inline and emit_inline(a.inline) or html_escape(a.value or "")
  local label = kind:sub(1, 1):upper() .. kind:sub(2)
  return ordinal(kind), label, text
end

local function footnote_number(n)
  local key = n.label or n
  local num = _fn.numbers[key]
  if not num then
    num = #_fn.order + 1
    _fn.numbers[key] = num
    _fn.order[num] = { label = n.label, content = n.content }
  elseif n.content and not _fn.order[num].content then
    _fn.order[num].content = n.content
  end
  return num
end

-- ox-html keeps non-numeric labels in ids; numeric labels are replaced
-- by the footnote number.
local function footnote_id(label, num)
  if label and not label:match("^%d+$") then
    return label
  end
  return tostring(num)
end

local function render_link(n)
  local desc = (n.description and #n.description > 0) and emit_inline(n.description) or nil
  local r = links.resolve(n.target, _index, ".html")
  if r.kind == "headline" then
    return '<a href="#'
      .. html_escape(r.anchor)
      .. '">'
      .. (desc or emit_inline(r.node.title))
      .. "</a>"
  elseif r.kind == "target" then
    return '<a href="#'
      .. html_escape(r.anchor)
      .. '">'
      .. (desc or html_escape(n.target))
      .. "</a>"
  elseif r.kind == "unresolved" then
    return "<i>" .. (desc or html_escape(n.target)) .. "</i>"
  end
  local url = r.kind == "file" and (r.path .. (r.fragment and ("#" .. r.fragment) or "")) or r.url
  local href = html_escape(url)
  return '<a href="' .. href .. '">' .. (desc or href) .. "</a>"
end

function emit_inline(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = plain_text(n.text or "")
    elseif n.kind == "emphasis" then
      local s = n.style
      -- Verbatim text is never smart-quoted (org-html-verbatim).
      local inner = (s == "verbatim" or s == "code") and html_escape(links.plain_text(n.content))
        or emit_inline(n.content)
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
    elseif n.kind == "radio_target" then
      out[#out + 1] = '<span id="'
        .. slug(n.phrase)
        .. '">'
        .. html_escape(n.phrase or "")
        .. "</span>"
    elseif n.kind == "link" then
      if n.form == "radio" then
        out[#out + 1] = '<a href="#'
          .. slug(n.target)
          .. '">'
          .. emit_inline(n.description)
          .. "</a>"
      else
        out[#out + 1] = render_link(n)
      end
    elseif n.kind == "image" then
      local target = html_escape(n.target or "")
      if n.alt and n.alt ~= "" then
        -- A described link is a hyperlink, never an inline image
        -- (org-html-inline-image-p).
        out[#out + 1] = '<a href="' .. target .. '">' .. html_escape(n.alt) .. "</a>"
      else
        out[#out + 1] = '<img src="' .. target .. '" alt="' .. target .. '">'
      end
    elseif n.kind == "footnote_ref" then
      local num = footnote_number(n)
      local id = html_escape(footnote_id(n.label, num))
      out[#out + 1] = '<sup><a href="#fn-' .. id .. '">[' .. num .. "]</a></sup>"
    elseif n.kind == "math" then
      _math_used = true
      if n.display then
        out[#out + 1] = "\\[" .. (n.body or "") .. "\\]"
      else
        out[#out + 1] = "$" .. (n.body or "") .. "$"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "<br>"
    elseif n.kind == "subscript" then
      out[#out + 1] = "<sub>" .. emit_inline(n.content) .. "</sub>"
    elseif n.kind == "superscript" then
      out[#out + 1] = "<sup>" .. emit_inline(n.content) .. "</sup>"
    elseif n.kind == "entity" then
      -- `\alpha{}` names the same entity as `\alpha`; the braces only
      -- terminate the name.
      local name = (n.name or ""):gsub("{}$", "")
      local e = ENTITIES[name]
      out[#out + 1] = e and e.html or html_escape("\\" .. name)
    elseif n.kind == "statistics_cookie" then
      out[#out + 1] = "<code>" .. html_escape(n.value) .. "</code>"
    elseif n.kind == "timestamp" then
      out[#out + 1] = '<span class="timestamp-wrapper"><span class="timestamp">'
        .. html_escape(n.value)
        .. "</span></span>"
    elseif n.kind == "target" then
      out[#out + 1] = '<a id="' .. html_escape(links.target_anchor(n.name)) .. '"></a>'
    elseif n.kind == "macro" then
      local args = (n.args and #n.args > 0) and ("(" .. table.concat(n.args, ",") .. ")") or ""
      out[#out + 1] = html_escape("{{{" .. (n.name or "") .. args .. "}}}")
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

-- Headline title with the parts ox-html adds around it: TODO keyword,
-- priority cookie and tags, each gated on its own export option.
local function headline_title(node)
  local parts = {}
  if _o.with_todo_keywords and node.todo and node.todo ~= "" then
    local kw = html_escape(node.todo)
    local cls = node.todo_type == "done" and "done" or "todo"
    parts[#parts + 1] = '<span class="' .. cls .. " " .. kw .. '">' .. kw .. "</span> "
  end
  if _o.with_priority and node.priority and node.priority ~= "" then
    parts[#parts + 1] = '<span class="priority">[' .. html_escape(node.priority) .. "]</span> "
  end
  parts[#parts + 1] = emit_inline(node.title or {})
  if _o.with_tags and node.tags and #node.tags > 0 then
    local tags = {}
    for _, t in ipairs(node.tags) do
      tags[#tags + 1] = '<span class="' .. html_escape(t) .. '">' .. html_escape(t) .. "</span>"
    end
    parts[#parts + 1] = '&#xa0;&#xa0;&#xa0;<span class="tag">'
      .. table.concat(tags, "&#xa0;")
      .. "</span>"
  end
  return table.concat(parts)
end

-- Advance the outline counter for `level` and return `1.2.` -- ox-html
-- resets every deeper counter when a shallower headline starts.
local function section_number(level)
  _secno[level] = (_secno[level] or 0) + 1
  for i = level + 1, #_secno do
    _secno[i] = nil
  end
  local parts = {}
  for i = 1, level do
    parts[#parts + 1] = tostring(_secno[i] or 0)
  end
  return table.concat(parts, ".") .. "."
end

local function emit_planning(node, out)
  local p = node.planning
  if not (_o.with_planning and p) then
    return
  end
  local parts = {}
  for _, k in ipairs({ "closed", "deadline", "scheduled" }) do
    if p[k] then
      parts[#parts + 1] = '<span class="timestamp-kwd">'
        .. k:upper()
        .. ':</span> <span class="timestamp">'
        .. html_escape(p[k])
        .. "</span>"
    end
  end
  if #parts > 0 then
    out[#out + 1] = '<p><span class="timestamp-wrapper">'
      .. table.concat(parts, " ")
      .. "</span></p>"
  end
end

local function wanted_property(key)
  local w = _o.with_properties
  if w == true then
    return true
  end
  if type(w) ~= "table" then
    return false
  end
  for _, k in ipairs(w) do
    if k:upper() == key then
      return true
    end
  end
  return false
end

local function emit_properties(node, out)
  if not (_o.with_properties and node.properties) then
    return
  end
  local keys = {}
  for k in pairs(node.properties) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local lines = {}
  for _, k in ipairs(keys) do
    if wanted_property(k) then
      lines[#lines + 1] = html_escape(k .. ": " .. node.properties[k])
    end
  end
  if #lines > 0 then
    out[#out + 1] = '<pre class="example">\n' .. table.concat(lines, "\n") .. "\n</pre>"
  end
end

-- ox.el `org-export-low-level-p`: `#+OPTIONS: H:N` renders a headline
-- deeper than N as a list item rather than as a heading.
local function low_level(n)
  return n.kind == "headline"
    and type(_o.headline_levels) == "number"
    and (n.level or 1) > _o.headline_levels
end

-- ox.el `org-export-numbered-headline-p`: `num:N` numbers only the first
-- N levels, so a deeper headline demotes to an unordered list.
local function numbered(n)
  local sec = _o.with_section_numbers
  if type(sec) == "number" then
    return (n.level or 1) <= sec
  end
  return not not sec
end

local emit_children

local function emit_low_level(nodes, out)
  local tag = numbered(nodes[1]) and "ol" or "ul"
  out[#out + 1] = "<" .. tag .. ">"
  for _, n in ipairs(nodes) do
    local sub = {}
    emit_planning(n, sub)
    emit_properties(n, sub)
    emit_children(n.children or {}, sub)
    out[#out + 1] = '<li><a id="'
      .. html_escape(links.headline_anchor(n))
      .. '"></a>'
      .. headline_title(n)
      .. "<br />"
      .. (#sub > 0 and ("\n" .. table.concat(sub, "\n")) or "")
      .. "</li>"
  end
  out[#out + 1] = "</" .. tag .. ">"
end

-- Walk a block list, gathering each run of demoted headline siblings into
-- a single list.
emit_children = function(children, out)
  local i, n = 1, #children
  while i <= n do
    if low_level(children[i]) then
      local run = {}
      while i <= n and low_level(children[i]) do
        run[#run + 1] = children[i]
        i = i + 1
      end
      emit_low_level(run, out)
    else
      emit_block(children[i], out)
      i = i + 1
    end
  end
end

local function emit_headline(node, out)
  local level = math.min(6, math.max(1, node.level or 1))
  local id = html_escape(links.headline_anchor(node))
  local number = ""
  if _o.with_section_numbers then
    number = '<span class="section-number-'
      .. level
      .. '">'
      .. section_number(node.level or 1)
      .. "</span> "
  end
  out[#out + 1] = "<h"
    .. level
    .. ' id="'
    .. id
    .. '">'
    .. number
    .. headline_title(node)
    .. "</h"
    .. level
    .. ">"
  emit_planning(node, out)
  emit_properties(node, out)
  local outer = _toc_scope
  _toc_scope = node
  emit_children(node.children or {}, out)
  _toc_scope = outer
end

local function emit_paragraph(node, out)
  out[#out + 1] = "<p>" .. emit_inline(node.inline or {}) .. "</p>"
end

local CHECKBOX_CLASS = { todo = "off", part = "trans", done = "on" }

-- The block sequence of one list item, first paragraph inlined so the
-- marker and its text share a line.
local function item_pieces(item, checkbox)
  local pieces = {}
  local first_para_done = false
  for _, b in ipairs(item.content or {}) do
    if b.kind == "paragraph" and not first_para_done then
      pieces[#pieces + 1] = checkbox .. emit_inline(b.inline)
      first_para_done = true
    else
      local sub_out = {}
      emit_block(b, sub_out)
      pieces[#pieces + 1] = table.concat(sub_out, "\n")
    end
  end
  if not first_para_done and checkbox ~= "" then
    table.insert(pieces, 1, checkbox)
  end
  return table.concat(pieces, "\n")
end

local function emit_description_list(node, out)
  out[#out + 1] = '<dl class="org-dl">'
  for _, item in ipairs(node.items or {}) do
    out[#out + 1] = "<dt>"
      .. emit_inline(item.tag or {})
      .. "</dt><dd>"
      .. item_pieces(item, "")
      .. "</dd>"
  end
  out[#out + 1] = "</dl>"
end

local function emit_list(node, out)
  local items = node.items or {}
  if items[1] and items[1].tag then
    return emit_description_list(node, out)
  end
  local tag = node.ordered and "ol" or "ul"
  out[#out + 1] = "<" .. tag .. ">"
  for _, item in ipairs(items) do
    local checkbox = ""
    if item.checkbox == "done" then
      checkbox = '<input type="checkbox" checked disabled> '
    elseif item.checkbox then
      checkbox = '<input type="checkbox" disabled> '
    end
    -- The tri-state class is what keeps `[-]` distinguishable from
    -- `[ ]`: HTML has no static indeterminate checkbox.
    local cls = CHECKBOX_CLASS[item.checkbox]
    local open = cls and ('<li class="' .. cls .. '">') or "<li>"
    out[#out + 1] = open .. item_pieces(item, checkbox) .. "</li>"
  end
  out[#out + 1] = "</" .. tag .. ">"
end

local function emit_code_block(node, out)
  local body = html_escape(node.body or "")
  local lang = node.language
  local num, label, text = caption_parts(node, "listing")
  if num then
    out[#out + 1] = '<label class="org-src-name"><span class="listing-number">'
      .. label
      .. " "
      .. num
      .. ": </span>"
      .. text
      .. "</label>"
  end
  local id = name_attr(node)
  if lang and lang ~= "" then
    out[#out + 1] = "<pre"
      .. id
      .. '><code class="language-'
      .. html_escape(lang)
      .. '">'
      .. body
      .. "</code></pre>"
  else
    out[#out + 1] = "<pre" .. id .. "><code>" .. body .. "</code></pre>"
  end
end

-- Verse keeps its inline markup but is whitespace-significant: a
-- newline becomes <br> and a leading space a non-breaking space.
local function verse_html(node)
  local s
  if node.content then
    local sub = {}
    for _, b in ipairs(node.content) do
      if b.kind == "paragraph" then
        sub[#sub + 1] = emit_inline(b.inline)
      else
        emit_block(b, sub)
      end
    end
    s = table.concat(sub, "\n")
  else
    s = html_escape(node.body or "")
  end
  local lines = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    local indent, rest = line:match("^( *)(.*)$")
    lines[#lines + 1] = string.rep("&#xa0;", #indent) .. rest .. "<br />"
  end
  if lines[#lines] == "<br />" then
    lines[#lines] = nil
  end
  return table.concat(lines, "\n")
end

local function emit_org_block(node, out)
  local style = node.style
  if style == "example" then
    out[#out + 1] = '<pre class="example">\n' .. html_escape(node.body or "") .. "\n</pre>"
  elseif style == "verse" then
    out[#out + 1] = '<p class="verse">\n' .. verse_html(node) .. "\n</p>"
  elseif style == "quote" then
    out[#out + 1] = "<blockquote>"
    for _, b in ipairs(node.content or {}) do
      emit_block(b, out)
    end
    out[#out + 1] = "</blockquote>"
  elseif style == "export" then
    if (node.backend or ""):lower() == "html" then
      out[#out + 1] = node.body or ""
    end
  elseif node.content then
    -- Every other greater block, `center` included, becomes a div
    -- classed after the block name (org-html-special-block).
    local cls = style == "center" and "org-center" or html_escape(style or "")
    out[#out + 1] = '<div class="' .. cls .. '">'
    for _, b in ipairs(node.content) do
      emit_block(b, out)
    end
    out[#out + 1] = "</div>"
  end
end

local function emit_fixed_width(node, out)
  out[#out + 1] = '<pre class="example"'
    .. name_attr(node)
    .. ">\n"
    .. html_escape(node.body or "")
    .. "\n</pre>"
end

local function emit_latex_environment(node, out)
  if _o.with_latex == "verbatim" then
    out[#out + 1] = "<p>" .. html_escape(node.body or "") .. "</p>"
  elseif _o.with_latex then
    _math_used = true
    out[#out + 1] = node.body or ""
  end
end

-- org-export-table-row-is-special-p: a row holding nothing but
-- alignment cookies (or a leading "/") is metadata, not data.
local function special_row(row)
  if row.sep or not row.cells then
    return false
  end
  if links.plain_text(row.cells[1] or {}) == "/" then
    return true
  end
  local cookie = false
  for _, cell in ipairs(row.cells) do
    local t = links.plain_text(cell)
    if t ~= "" then
      if t:match("^<[lrc]?%d*>$") then
        cookie = true
      else
        return false
      end
    end
  end
  return cookie
end

-- org-table-number-regexp, trimmed to what a Lua pattern can express.
local NUMBER = "^[<>]?[-+%^.%d]*%d[-+%^.%deEdDx()%%:]*$"

-- org-export-table-cell-alignment: an explicit cookie wins; otherwise a
-- column that is at least `org-table-number-fraction` numbers goes right.
local function table_alignments(node)
  local cookies, ncols = {}, 0
  for _, r in ipairs(node.rows or {}) do
    if not r.sep and r.cells then
      if #r.cells > ncols then
        ncols = #r.cells
      end
      if special_row(r) then
        for c, cell in ipairs(r.cells) do
          local a = links.plain_text(cell):match("^<([lrc])")
          if a then
            cookies[c] = a
          end
        end
      end
    end
  end
  local align = {}
  for c = 1, ncols do
    local declared = (node.alignments or {})[c]
    if cookies[c] then
      align[c] = cookies[c]
    elseif declared and declared ~= "l" then
      align[c] = declared
    else
      local total, nums, prev_num = 0, 0, false
      for _, r in ipairs(node.rows or {}) do
        if not r.sep and r.cells and not special_row(r) then
          local v = links.plain_text(r.cells[c] or {})
          total = total + 1
          if v:match(NUMBER) or (v == "" and prev_num) then
            nums, prev_num = nums + 1, true
          else
            prev_num = false
          end
        end
      end
      align[c] = (total > 0 and nums / total >= 0.5) and "r" or "l"
    end
  end
  return align
end

local ALIGN_CLASS = { l = "org-left", r = "org-right", c = "org-center" }

local function emit_table(node, out)
  local rows = {}
  for _, r in ipairs(node.rows or {}) do
    if not special_row(r) then
      rows[#rows + 1] = r
    end
  end
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

  local align = table_alignments(node)

  local function emit_row(row, cell_tag, out_buf)
    local parts = {}
    for c = 1, ncols do
      local cls = ALIGN_CLASS[align[c]]
      parts[#parts + 1] = "<"
        .. cell_tag
        .. (cls and (' class="' .. cls .. '"') or "")
        .. ">"
        .. emit_inline(row.cells[c] or {})
        .. "</"
        .. cell_tag
        .. ">"
    end
    out_buf[#out_buf + 1] = "<tr>" .. table.concat(parts) .. "</tr>"
  end

  out[#out + 1] = "<table" .. name_attr(node) .. attr_html(node) .. ">"
  local num, label, text = caption_parts(node, "table")
  if num then
    out[#out + 1] = '<caption class="t-above"><span class="table-number">'
      .. label
      .. " "
      .. num
      .. ":</span> "
      .. text
      .. "</caption>"
  end
  local cols = {}
  for c = 1, ncols do
    local cls = ALIGN_CLASS[align[c]]
    cols[#cols + 1] = "<col" .. (cls and (' class="' .. cls .. '"') or "") .. " />"
  end
  out[#out + 1] = "<colgroup>" .. table.concat(cols) .. "</colgroup>"
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
  if node.alt and node.alt ~= "" then
    out[#out + 1] = '<p><a href="' .. target .. '">' .. html_escape(node.alt) .. "</a></p>"
    return
  end
  local num, label, text = caption_parts(node, "figure")
  local img = '<img src="' .. target .. '" alt="' .. target .. '"' .. attr_html(node) .. ">"
  if num then
    out[#out + 1] = "<div"
      .. name_attr(node)
      .. ' class="figure"><p>'
      .. img
      .. '</p><p><span class="figure-number">'
      .. label
      .. " "
      .. num
      .. ": </span>"
      .. text
      .. "</p></div>"
  else
    out[#out + 1] = "<p" .. name_attr(node) .. ">" .. img .. "</p>"
  end
end

local function emit_rule(_, out)
  out[#out + 1] = "<hr>"
end

local function emit_footnote_definition(id, num, content, out)
  local id_esc = html_escape(id)
  local first_body = ""
  if content[1] and content[1].kind == "paragraph" then
    first_body = emit_inline(content[1].inline)
  end
  local pieces = {
    '<div class="footdef" id="fn-' .. id_esc .. '"><sup>[' .. num .. "]</sup> " .. first_body,
  }
  for i = 2, #content do
    local b = content[i]
    if b.kind == "paragraph" then
      pieces[#pieces + 1] = "<p>" .. emit_inline(b.inline) .. "</p>"
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
  elseif kind == "fixed_width" then
    emit_fixed_width(node, out)
  elseif kind == "latex_environment" then
    emit_latex_environment(node, out)
  elseif kind == "directive" and (node.name or ""):upper() == "TOC" then
    emit_toc_keyword(node.value or "", out)
  end
  -- footnote_definition renders in the footnotes section; other
  -- directives, drawer, comment, and unknown kinds drop silently.
end

local function find_title(doc)
  if not doc or not doc.children then
    return nil
  end
  local o = doc.options or {}
  if o.title and o.title ~= "" then
    return o.title
  end
  for _, c in ipairs(doc.children) do
    if c.kind == "directive" and c.name == "TITLE" then
      return c.value
    end
  end
  for _, c in ipairs(doc.children) do
    if c.kind == "headline" then
      return links.plain_text(c.title)
    end
  end
  return nil
end

-- Collect headlines in document order with their outline numbers, so
-- the TOC can be built without re-walking during body emission.
local function toc_entries(doc, depth)
  local entries, counters = {}, {}
  local function walk(nodes, level)
    for _, c in ipairs(nodes or {}) do
      if c.kind == "headline" then
        local l = c.level or level
        counters[l] = (counters[l] or 0) + 1
        for i = l + 1, #counters do
          counters[i] = nil
        end
        if l <= depth then
          local num = {}
          for i = 1, l do
            num[#num + 1] = tostring(counters[i] or 0)
          end
          entries[#entries + 1] = {
            level = l,
            number = table.concat(num, ".") .. ".",
            anchor = links.headline_anchor(c),
            title = headline_title(c),
          }
        end
        walk(c.children, l + 1)
      end
    end
  end
  walk(doc.children, 1)
  return entries
end

-- `scope` is the headline a local TOC covers (nil for the whole
-- document); a local TOC is the bare list, with no title around it.
local function emit_toc_list(scope, out, depth, bare)
  local entries = toc_entries(scope, depth)
  if #entries == 0 then
    return
  end
  local id = "text-table-of-contents"
  if bare then
    -- ox-html suffixes each further TOC so the ids stay unique.
    _toc_count = _toc_count + 1
    id = id .. "-" .. _toc_count
  else
    out[#out + 1] = '<div id="table-of-contents" role="doc-toc">'
    out[#out + 1] = "<h2>Table of Contents</h2>"
  end
  out[#out + 1] = '<div id="' .. id .. '" role="doc-toc">'
  local base = entries[1].level
  for _, e in ipairs(entries) do
    if e.level < base then
      base = e.level
    end
  end
  local prev = 0
  for _, e in ipairs(entries) do
    local level = e.level - base + 1
    if level > prev then
      for _ = prev + 1, level do
        out[#out + 1] = "<ul>"
      end
    else
      for _ = level, prev - 1 do
        out[#out + 1] = "</li>"
        out[#out + 1] = "</ul>"
      end
      out[#out + 1] = "</li>"
    end
    local num = _o.with_section_numbers and (e.number .. " ") or ""
    out[#out + 1] = '<li><a href="#' .. html_escape(e.anchor) .. '">' .. num .. e.title .. "</a>"
    prev = level
  end
  for _ = 1, prev - 1 do
    out[#out + 1] = "</li>"
    out[#out + 1] = "</ul>"
  end
  out[#out + 1] = "</li>"
  out[#out + 1] = "</ul>"
  out[#out + 1] = "</div>"
  if not bare then
    out[#out + 1] = "</div>"
  end
end

local function emit_toc(doc, out)
  local depth = _o.with_toc
  if not depth then
    return
  end
  if type(depth) ~= "number" then
    depth = _o.headline_levels or 3
  end
  emit_toc_list(doc, out, depth, false)
end

-- Every captioned node of `kind`, numbered as the body numbers them.
local function caption_entries(doc, kind)
  local want = ({ table = "table", listing = "code_block", figure = "image" })[kind]
  local entries = {}
  A.walk(doc, function(n)
    if n.kind == want and affiliated(n, "CAPTION") then
      local a = affiliated(n, "CAPTION")
      entries[#entries + 1] = {
        number = #entries + 1,
        text = a.inline and emit_inline(a.inline) or html_escape(a.value or ""),
      }
    end
  end)
  return entries
end

local function emit_caption_list(doc, kind, title, out)
  local entries = caption_entries(doc, kind)
  if #entries == 0 then
    return
  end
  local id = "list-of-" .. kind .. "s"
  out[#out + 1] = '<div id="' .. id .. '">'
  out[#out + 1] = "<h2>" .. title .. "</h2>"
  out[#out + 1] = '<div id="text-' .. id .. '">'
  out[#out + 1] = "<ul>"
  local label = kind:sub(1, 1):upper() .. kind:sub(2)
  for _, e in ipairs(entries) do
    out[#out + 1] = '<li><span class="'
      .. kind
      .. '-number">'
      .. label
      .. " "
      .. e.number
      .. ":</span> "
      .. e.text
      .. "</li>"
  end
  out[#out + 1] = "</ul>"
  out[#out + 1] = "</div>"
  out[#out + 1] = "</div>"
end

-- org-html-keyword: `#+TOC: headlines N [local]`, `tables`, `listings`.
-- `figures` is accepted and, as in ox-html, renders nothing.
emit_toc_keyword = function(value, out)
  local v = value:lower()
  local limit = type(_o.headline_levels) == "number" and _o.headline_levels or 3
  if v:find("headlines") then
    local n = tonumber(v:match("%f[%d]%d+%f[%D]"))
    local scope = v:find("local") and _toc_scope or nil
    local depth = limit
    if n then
      depth = math.min(scope and ((scope.level or 1) + n) or n, limit)
    end
    emit_toc_list(scope or _doc, out, depth, scope ~= nil)
  elseif v:find("tables") then
    emit_caption_list(_doc, "table", "List of Tables", out)
  elseif v:find("listings") then
    emit_caption_list(_doc, "listing", "List of Listings", out)
  end
end

-- Number footnotes by first reference and collect block definitions,
-- in document order.
local function prepare(doc)
  _doc = doc
  _toc_scope = nil
  _toc_count = 0
  _index = links.index(doc)
  _fn = { numbers = {}, order = {} }
  _o = (doc and doc.options) or OPTIONS.defaults()
  _secno, _ordinal = {}, {}
  local defs = {}
  A.walk(doc, function(n)
    if n.kind == "footnote_ref" then
      footnote_number(n)
    elseif n.kind == "footnote_definition" then
      defs[n.label or ""] = defs[n.label or ""] or n.content
    end
  end)
  return defs
end

function M.render(doc, opts)
  opts = opts or {}
  _math_used = false
  local defs = prepare(doc)

  local title = find_title(doc) or "Untitled"

  local body = {}
  emit_toc(doc, body)
  emit_children(doc.children or {}, body)
  for num, entry in ipairs(_fn.order) do
    local content = entry.content and { A.paragraph(entry.content) } or defs[entry.label or ""]
    if content then
      emit_footnote_definition(footnote_id(entry.label, num), num, content, body)
    end
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

  local meta = {}
  local function add_meta(name, content)
    if content and content ~= "" then
      meta[#meta + 1] = '  <meta name="' .. name .. '" content="' .. html_escape(content) .. '">'
    end
  end
  if _o.with_author then
    local author = _o.author
    if author and _o.with_email and _o.email and _o.email ~= "" then
      author = author .. " <" .. _o.email .. ">"
    end
    add_meta("author", author)
  end
  if _o.with_date then
    add_meta("dcterms.date", _o.date)
  end
  if _o.with_creator then
    add_meta("generator", _o.creator or "organ.nvim")
  end

  local out = {
    "<!DOCTYPE html>",
    '<html lang="' .. html_escape(_o.language or "en") .. '">',
    "<head>",
    '  <meta charset="utf-8">',
    '  <meta name="viewport" content="width=device-width, initial-scale=1">',
  }
  if _o.time_stamp_file then
    out[#out + 1] = "  <!-- " .. os.date("%Y-%m-%d %a %H:%M") .. " -->"
  end
  if _o.with_title then
    out[#out + 1] = "  <title>" .. html_escape(title) .. "</title>"
  end
  for _, l in ipairs(meta) do
    out[#out + 1] = l
  end
  out[#out + 1] = "  " .. style_block
  out[#out + 1] = "  " .. mathjax_block
  out[#out + 1] = "</head>"
  out[#out + 1] = "<body>"
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
