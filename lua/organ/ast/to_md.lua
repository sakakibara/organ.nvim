-- Document AST -> CommonMark / GFM string.
--
-- Companion to from_org.lua.  Renders every AST kind that from_org
-- emits, with GFM extensions (tables, strikethrough, task-list
-- checkboxes) plus pandoc-style math ($...$ / $$...$$) and footnotes
-- ([^n] / [^n]: body).  Inline kinds without a markdown form take
-- their HTML form, as ox-md does.

local A = require("organ.ast")
local links = require("organ.ast.links")
local ENTITIES = require("organ.ast.org_entities")

local M = {}

local emit_inline
local emit_block

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

-- org-md-plain-text
local function escape_text(s)
  if not s or s == "" then
    return ""
  end
  s = s:gsub("[`*_\\]", "\\%0")
  s = s:gsub("\n#", "\n\\#")
  s = s:gsub("!%[", "\\![")
  return s
end

local function raw_text(nodes, out)
  for _, c in ipairs(nodes or {}) do
    if c.kind == "text" or c.kind == "raw_inline" then
      out[#out + 1] = c.text or ""
    elseif c.content then
      raw_text(c.content, out)
    end
  end
  return out
end

-- Per-render state: link destinations, headlines that are linked to,
-- and footnotes numbered by first reference.
local _index
local _referred = {}
local _fn = { numbers = {}, order = {} }

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

local function render_link(n)
  local desc = (n.description and #n.description > 0) and emit_inline(n.description) or nil
  local r = links.resolve(n.target, _index, ".md")
  if r.kind == "headline" then
    return "[" .. (desc or emit_inline(r.node.title)) .. "](#" .. r.anchor .. ")"
  elseif r.kind == "target" then
    return "[" .. (desc or escape_text(n.target)) .. "](#" .. r.anchor .. ")"
  elseif r.kind == "unresolved" then
    return desc or escape_text(n.target)
  end
  local url = r.kind == "file" and (r.path .. (r.fragment and ("#" .. r.fragment) or "")) or r.url
  if desc then
    return "[" .. desc .. "](" .. url .. ")"
  end
  return "[" .. url .. "](" .. url .. ")"
end

function emit_inline(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = escape_text(n.text)
    elseif n.kind == "emphasis" then
      local s = n.style
      if s == "verbatim" or s == "code" then
        out[#out + 1] = "`" .. table.concat(raw_text(n.content, {})) .. "`"
      else
        local inner = emit_inline(n.content)
        if s == "bold" then
          out[#out + 1] = "**" .. inner .. "**"
        elseif s == "italic" then
          out[#out + 1] = "*" .. inner .. "*"
        elseif s == "underline" then
          out[#out + 1] = "<u>" .. inner .. "</u>"
        elseif s == "strike" then
          out[#out + 1] = "~~" .. inner .. "~~"
        else
          out[#out + 1] = inner
        end
      end
    elseif n.kind == "radio_target" then
      out[#out + 1] = escape_text(n.phrase)
    elseif n.kind == "link" then
      if n.form == "radio" then
        out[#out + 1] = emit_inline(n.description)
      else
        out[#out + 1] = render_link(n)
      end
    elseif n.kind == "image" then
      local target = n.target or ""
      local alt = n.alt and n.alt ~= "" and n.alt or target
      out[#out + 1] = "![" .. alt .. "](" .. target .. ")"
    elseif n.kind == "footnote_ref" then
      out[#out + 1] = "[^" .. footnote_number(n) .. "]"
    elseif n.kind == "math" then
      if n.display then
        out[#out + 1] = "$$" .. (n.body or "") .. "$$"
      else
        out[#out + 1] = "$" .. (n.body or "") .. "$"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "  \n"
    elseif n.kind == "subscript" then
      out[#out + 1] = "<sub>" .. emit_inline(n.content) .. "</sub>"
    elseif n.kind == "superscript" then
      out[#out + 1] = "<sup>" .. emit_inline(n.content) .. "</sup>"
    elseif n.kind == "entity" then
      local e = ENTITIES[n.name or ""]
      out[#out + 1] = e and e.html or escape_text("\\" .. (n.name or ""))
    elseif n.kind == "statistics_cookie" then
      out[#out + 1] = "<code>" .. html_escape(n.value) .. "</code>"
    elseif n.kind == "timestamp" then
      out[#out + 1] = '<span class="timestamp-wrapper"><span class="timestamp">'
        .. html_escape(n.value)
        .. "</span></span>"
    elseif n.kind == "target" then
      out[#out + 1] = '<a id="' .. links.target_anchor(n.name) .. '"></a>'
    elseif n.kind == "macro" then
      local args = (n.args and #n.args > 0) and ("(" .. table.concat(n.args, ",") .. ")") or ""
      out[#out + 1] = escape_text("{{{" .. (n.name or "") .. args .. "}}}")
    elseif n.kind == "raw_inline" then
      out[#out + 1] = n.text or ""
    end
  end
  local s = table.concat(out)
  local ok, cite = pcall(require, "organ.cite")
  if ok and type(cite.replace_in) == "function" then
    s = cite.replace_in(s, "markdown")
  end
  return s
end

local function emit_headline(node, out)
  local level = math.min(6, math.max(1, node.level or 1))
  local anchor = links.headline_anchor(node)
  if _referred[anchor] then
    out[#out + 1] = '<a id="' .. anchor .. '"></a>'
    out[#out + 1] = ""
  end
  out[#out + 1] = string.rep("#", level) .. " " .. emit_inline(node.title or {})
  out[#out + 1] = ""
end

-- org-md-paragraph: a paragraph-leading `#` is protected.
local function paragraph_text(node)
  local txt = emit_inline(node.inline or {})
  local first = node.inline and node.inline[1]
  if first and first.kind == "text" and (first.text or ""):sub(1, 1) == "#" then
    txt = "\\" .. txt
  end
  return txt
end

local function emit_paragraph(node, out)
  out[#out + 1] = paragraph_text(node)
  out[#out + 1] = ""
end

-- Append `lines` (each may hold embedded newlines) to `out`, prefixing
-- every non-blank line with `prefix`.
local function indent_into(lines, prefix, out)
  for _, l in ipairs(lines) do
    for piece in (l .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = piece == "" and "" or (prefix .. piece)
    end
  end
end

local function emit_list(node, out, indent)
  indent = indent or ""
  local n = 1
  for _, item in ipairs(node.items or {}) do
    local marker = node.ordered and (n .. ".") or "-"
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = "[ ] "
    elseif item.checkbox == "done" then
      checkbox = "[x] "
    elseif item.checkbox == "part" then
      checkbox = "[ ] "
    end
    local content_indent = indent .. string.rep(" ", #marker + 1)
    local first = true
    local function open_item(txt)
      local head, rest = (txt or ""):match("^([^\n]*)\n?(.*)$")
      out[#out + 1] = (indent .. marker .. " " .. checkbox .. head):gsub("%s+$", "")
      if rest ~= "" then
        indent_into({ rest }, content_indent, out)
      end
      first = false
    end
    for _, b in ipairs(item.content or {}) do
      if b.kind == "paragraph" and first then
        open_item(paragraph_text(b))
      elseif b.kind == "list" then
        if first then
          open_item()
        end
        emit_list(b, out, content_indent)
      else
        if first then
          open_item()
        end
        out[#out + 1] = ""
        local sub = {}
        emit_block(b, sub)
        while #sub > 0 and sub[#sub] == "" do
          sub[#sub] = nil
        end
        indent_into(sub, content_indent, out)
      end
    end
    if first then
      open_item()
    end
    n = n + 1
  end
  if indent == "" then
    out[#out + 1] = ""
  end
end

local function emit_code_block(node, out)
  out[#out + 1] = "```" .. (node.language or "")
  for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  -- Drop the trailing empty produced by the splitter when body ends
  -- with a newline (or is empty) -- the closing fence on its own line
  -- is what we want, not a blank line before it.
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = "```"
  out[#out + 1] = ""
end

-- Org-style block kinds (quote / verse / example / export).
-- Named emit_org_block to disambiguate from the AST kind "block".
local function emit_org_block(node, out)
  local style = node.style
  if style == "quote" then
    -- Render content into a sub-buffer, then prefix each line with "> ".
    local sub = {}
    for _, b in ipairs(node.content or {}) do
      emit_block(b, sub)
    end
    -- Drop the trailing empty the inner emitters add so we don't get
    -- a `> ` on a blank line.
    while #sub > 0 and sub[#sub] == "" do
      sub[#sub] = nil
    end
    for _, line in ipairs(sub) do
      if line == "" then
        out[#out + 1] = ">"
      else
        out[#out + 1] = "> " .. line
      end
    end
    out[#out + 1] = ""
  elseif style == "verse" or style == "example" then
    out[#out + 1] = "```"
    for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = line
    end
    if out[#out] == "" then
      out[#out] = nil
    end
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  -- export and unknown styles drop silently.
end

local ALIGN_CELL = { l = "---", r = "---:", c = ":---:" }

local function emit_table(node, out)
  local rows = node.rows or {}
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

  -- GFM needs exactly one delimiter row, right after the header row;
  -- org separator rows carry no other information here.
  local header_done = false
  for _, row in ipairs(rows) do
    if not row.sep then
      local cells = {}
      for i = 1, ncols do
        cells[i] = emit_inline(row.cells[i] or {})
      end
      out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
      if not header_done then
        local delims = {}
        for i = 1, ncols do
          delims[i] = ALIGN_CELL[(node.alignments or {})[i]] or "---"
        end
        out[#out + 1] = "| " .. table.concat(delims, " | ") .. " |"
        header_done = true
      end
    end
  end
  out[#out + 1] = ""
end

local function emit_image_block(node, out)
  local target = node.target or ""
  local alt = node.alt and node.alt ~= "" and node.alt or target
  out[#out + 1] = "![" .. alt .. "](" .. target .. ")"
  out[#out + 1] = ""
end

local function emit_rule(_, out)
  out[#out + 1] = "---"
  out[#out + 1] = ""
end

local function emit_footnote_definition(label, content, out)
  local first_body = ""
  if content[1] and content[1].kind == "paragraph" then
    first_body = emit_inline(content[1].inline)
  end
  out[#out + 1] = "[^" .. label .. "]: " .. first_body
  for i = 2, #content do
    local b = content[i]
    if b.kind == "paragraph" then
      out[#out + 1] = "    " .. emit_inline(b.inline)
    end
  end
  out[#out + 1] = ""
end

function emit_block(node, out)
  local kind = node.kind
  if kind == "headline" then
    emit_headline(node, out)
    for _, c in ipairs(node.children or {}) do
      emit_block(c, out)
    end
  elseif kind == "paragraph" then
    emit_paragraph(node, out)
  elseif kind == "list" then
    emit_list(node, out, "")
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
  end
  -- footnote_definition renders in the footnotes section; other kinds
  -- drop silently.
end

local function collapse_blank_runs(lines)
  local collapsed = {}
  local prev_blank = false
  for _, l in ipairs(lines) do
    if l == "" then
      if not prev_blank then
        collapsed[#collapsed + 1] = ""
      end
      prev_blank = true
    else
      collapsed[#collapsed + 1] = l
      prev_blank = false
    end
  end
  while #collapsed > 0 and collapsed[#collapsed] == "" do
    collapsed[#collapsed] = nil
  end
  return collapsed
end

-- Number footnotes by first reference, record linked-to headlines,
-- and collect block definitions, all in document order.
local function prepare(doc)
  _index = links.index(doc)
  _referred = {}
  _fn = { numbers = {}, order = {} }
  local defs = {}
  A.walk(doc, function(n)
    if n.kind == "footnote_ref" then
      footnote_number(n)
    elseif n.kind == "footnote_definition" then
      defs[n.label or ""] = defs[n.label or ""] or n.content
    elseif n.kind == "link" and n.form ~= "radio" then
      local r = links.resolve(n.target, _index, ".md")
      if r.kind == "headline" then
        _referred[r.anchor] = true
      end
    end
  end)
  return defs
end

function M.render(doc, _opts)
  local defs = prepare(doc)
  local out = {}
  for _, c in ipairs(doc.children or {}) do
    emit_block(c, out)
  end
  for num, entry in ipairs(_fn.order) do
    local content = entry.content and { A.paragraph(entry.content) } or defs[entry.label or ""]
    if content then
      emit_footnote_definition(tostring(num), content, out)
    end
  end
  local collapsed = collapse_blank_runs(out)
  return table.concat(collapsed, "\n") .. "\n"
end

-- Expose internals for tests.
M._emit_inline = emit_inline
M._emit_block = emit_block

return M
