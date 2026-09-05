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
local OPTIONS = require("organ.export.options")

local M = {}

local emit_inline
local emit_block
local emit_toc_keyword
-- The document being rendered, and the headline a `#+TOC: ... local`
-- sits under while its section emits.
local _doc
local _toc_scope

-- Resolved export options.
local _o = OPTIONS.defaults()

local function affiliated(node, name)
  for _, a in ipairs(node.affiliated or {}) do
    if a.name == name then
      return a
    end
  end
end

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

-- org-export-activate-smart-quotes, on already-escaped text.
local function smart_quotes(s)
  s = s:gsub('()"', function(pos)
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

-- org-md-plain-text
local function escape_text(s)
  if not s or s == "" then
    return ""
  end
  s = s:gsub("[`*_\\]", "\\%0")
  s = s:gsub("\n#", "\n\\#")
  s = s:gsub("!%[", "\\![")
  if _o.with_special_strings then
    s = s:gsub("%-%-%-", "&#x2014;"):gsub("%-%-", "&#x2013;"):gsub("%.%.%.", "&#x2026;")
  end
  if _o.with_smart_quotes then
    s = smart_quotes(s)
  end
  if _o.preserve_breaks then
    s = s:gsub("\n", "  \n")
  end
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
      if n.alt and n.alt ~= "" then
        -- A described link is a hyperlink, never an inline image.
        out[#out + 1] = "[" .. escape_text(n.alt) .. "](" .. target .. ")"
      else
        out[#out + 1] = "![" .. target .. "](" .. target .. ")"
      end
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
      -- `\alpha{}` names the same entity as `\alpha`; the braces only
      -- terminate the name.
      local name = (n.name or ""):gsub("{}$", "")
      local e = ENTITIES[name]
      out[#out + 1] = e and e.html or escape_text("\\" .. name)
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

-- org-md-headline: TODO keyword and priority cookie lead the title,
-- tags trail it, each gated on its own export option.
local function headline_title(node, no_tags)
  local parts = {}
  if _o.with_todo_keywords and node.todo and node.todo ~= "" then
    parts[#parts + 1] = node.todo .. " "
  end
  if _o.with_priority and node.priority and node.priority ~= "" then
    parts[#parts + 1] = "[#" .. node.priority .. "] "
  end
  parts[#parts + 1] = emit_inline(node.title or {})
  if not no_tags and _o.with_tags and node.tags and #node.tags > 0 then
    parts[#parts + 1] = "     :" .. table.concat(node.tags, ":") .. ":"
  end
  return table.concat(parts)
end

local function emit_headline(node, out)
  local level = math.min(6, math.max(1, node.level or 1))
  local anchor = links.headline_anchor(node)
  if _referred[anchor] then
    out[#out + 1] = '<a id="' .. anchor .. '"></a>'
    out[#out + 1] = ""
  end
  out[#out + 1] = string.rep("#", level) .. " " .. headline_title(node)
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
      checkbox = "[-] "
    end
    -- `- term :: definition` has no markdown form; ox-md renders the
    -- term as bold lead-in text.
    local term = item.tag and ("**" .. emit_inline(item.tag) .. ":** ") or ""
    local content_indent = indent .. string.rep(" ", #marker + 1)
    local first = true
    local function open_item(txt)
      local head, rest = (term .. (txt or "")):match("^([^\n]*)\n?(.*)$")
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

local function emit_indented(body, out)
  for line in ((body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line == "" and "" or ("    " .. line)
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = ""
end

local function emit_fixed_width(node, out)
  emit_indented(node.body, out)
end

local function emit_latex_environment(node, out)
  if not _o.with_latex then
    return
  end
  for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = _o.with_latex == "verbatim" and escape_text(line) or line
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = ""
end

local function emit_code_block(node, out)
  local caption = affiliated(node, "CAPTION")
  if caption then
    out[#out + 1] = "*" .. (caption.inline and emit_inline(caption.inline) or caption.value) .. "*"
    out[#out + 1] = ""
  end
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
  elseif style == "example" then
    emit_indented(node.body, out)
  elseif style == "verse" then
    -- Verse is whitespace-significant and keeps its inline markup, so
    -- neither a code fence nor a plain paragraph will do.
    local sub = {}
    for _, b in ipairs(node.content or {}) do
      if b.kind == "paragraph" then
        sub[#sub + 1] = emit_inline(b.inline)
      else
        emit_block(b, sub)
      end
    end
    local body = node.content and table.concat(sub, "\n") or (node.body or "")
    out[#out + 1] = '<p class="verse">'
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
      local lead, rest = line:match("^( *)(.*)$")
      out[#out + 1] = string.rep("&#xa0;", #lead) .. rest .. "<br />"
    end
    if out[#out] == "<br />" then
      out[#out] = nil
    end
    out[#out + 1] = "</p>"
    out[#out + 1] = ""
  elseif style == "export" then
    local backend = (node.backend or ""):lower()
    if backend == "md" or backend == "markdown" or backend == "html" then
      for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
      if out[#out] == "" then
        out[#out] = nil
      end
      out[#out + 1] = ""
    end
  elseif node.content then
    -- Every other greater block, `center` included, becomes a div named
    -- after it.  The blank lines keep the inner markdown parsed rather
    -- than swallowed by the raw-HTML block, which is what ox-md does.
    local cls = style == "center" and "org-center" or (style or "")
    out[#out + 1] = '<div class="' .. cls .. '">'
    out[#out + 1] = ""
    for _, b in ipairs(node.content) do
      emit_block(b, out)
    end
    while #out > 0 and out[#out] == "" do
      out[#out] = nil
    end
    out[#out + 1] = ""
    out[#out + 1] = "</div>"
    out[#out + 1] = ""
  end
end

local ALIGN_CELL = { l = "---", r = "---:", c = ":---:" }

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

local function emit_table(node, out)
  local rows = {}
  for _, r in ipairs(node.rows or {}) do
    if not special_row(r) then
      rows[#rows + 1] = r
    end
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
  local align = table_alignments(node)
  local caption = affiliated(node, "CAPTION")
  if caption then
    out[#out + 1] = "*" .. (caption.inline and emit_inline(caption.inline) or caption.value) .. "*"
    out[#out + 1] = ""
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
          delims[i] = ALIGN_CELL[align[i]] or "---"
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
  if node.alt and node.alt ~= "" then
    out[#out + 1] = "[" .. escape_text(node.alt) .. "](" .. target .. ")"
    out[#out + 1] = ""
    return
  end
  local caption = affiliated(node, "CAPTION")
  local title = caption and (' "' .. (caption.value or ""):gsub('"', '\\"') .. '"') or ""
  out[#out + 1] = "![" .. target .. "](" .. target .. title .. ")"
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

-- Rewrite each run of demoted headline siblings into one list node, so
-- the ordinary list emitter handles markers and indentation.
local function demote(children)
  local out, i, n = {}, 1, #children
  while i <= n do
    if low_level(children[i]) then
      local items = {}
      local first = children[i]
      while i <= n and low_level(children[i]) do
        local h = children[i]
        local anchor = links.headline_anchor(h)
        local head = headline_title(h)
        if _referred[anchor] then
          head = '<a id="' .. anchor .. '"></a>' .. head
        end
        local content = { A.paragraph({ A.raw_inline(head) }) }
        for _, b in ipairs(demote(h.children or {})) do
          content[#content + 1] = b
        end
        items[#items + 1] = A.list_item({ content = content })
        i = i + 1
      end
      out[#out + 1] = A.list(numbered(first), items)
    else
      out[#out + 1] = children[i]
      i = i + 1
    end
  end
  return out
end

function emit_block(node, out)
  local kind = node.kind
  if kind == "headline" then
    emit_headline(node, out)
    local outer = _toc_scope
    _toc_scope = node
    for _, c in ipairs(demote(node.children or {})) do
      emit_block(c, out)
    end
    _toc_scope = outer
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
  elseif kind == "fixed_width" then
    emit_fixed_width(node, out)
  elseif kind == "latex_environment" then
    emit_latex_environment(node, out)
  elseif kind == "directive" and (node.name or ""):upper() == "TOC" then
    emit_toc_keyword(node.value or "", out)
  end
  -- footnote_definition renders in the footnotes section; other kinds
  -- drop silently.
end

local function toc_tags(node)
  if _o.with_tags and node.tags and #node.tags > 0 then
    return ":" .. table.concat(node.tags, ":") .. ":"
  end
  return ""
end

-- Table of contents: a nested ordered list, as ox-md builds it.
-- `scope` is the headline a local TOC covers (nil for the whole
-- document); a local TOC is the bare list, with no title above it.
local function emit_toc_list(scope, out, depth, bare)
  local entries = {}
  local function walk(nodes)
    for _, c in ipairs(nodes or {}) do
      if c.kind == "headline" then
        if (c.level or 1) <= depth then
          entries[#entries + 1] = { level = c.level or 1, node = c }
        end
        walk(c.children)
      end
    end
  end
  walk(scope.children)
  if #entries == 0 then
    return
  end
  local base = entries[1].level
  for _, e in ipairs(entries) do
    if e.level < base then
      base = e.level
    end
  end
  if not bare then
    out[#out + 1] = "# Table of Contents"
    out[#out + 1] = ""
  end
  local counters = {}
  for _, e in ipairs(entries) do
    local depth_here = e.level - base + 1
    counters[depth_here] = (counters[depth_here] or 0) + 1
    for i = depth_here + 1, #counters do
      counters[i] = nil
    end
    out[#out + 1] = string.rep("    ", depth_here - 1)
      .. counters[depth_here]
      .. ".  ["
      .. headline_title(e.node, true)
      .. "](#"
      .. links.headline_anchor(e.node)
      .. ")"
      .. toc_tags(e.node)
  end
  out[#out + 1] = ""
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

-- org-md-keyword: `#+TOC: headlines N`, optionally scoped by `local` or
-- `:target LINK`.  ox-md has no list of tables or listings.
emit_toc_keyword = function(value, out)
  local v = value:lower()
  if not v:find("headlines") then
    return
  end
  local limit = type(_o.headline_levels) == "number" and _o.headline_levels or 3
  local n = tonumber(v:match("%f[%d]%d+%f[%D]"))
  local scope
  local target = value:match(':target%s+"(.-)"') or value:match(":target%s+(%S+)")
  if target then
    local r = links.resolve(target, _index, ".md")
    scope = r.kind == "headline" and r.node or nil
  elseif v:find("local") then
    scope = _toc_scope
  end
  local depth = limit
  if n then
    depth = math.min(scope and ((scope.level or 1) + n) or n, limit)
  end
  emit_toc_list(scope or _doc, out, depth, scope ~= nil)
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
  _doc = doc
  _toc_scope = nil
  _index = links.index(doc)
  _referred = {}
  _fn = { numbers = {}, order = {} }
  _o = (doc and doc.options) or OPTIONS.defaults()
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
  emit_toc(doc, out)
  for _, c in ipairs(demote(doc.children or {})) do
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
