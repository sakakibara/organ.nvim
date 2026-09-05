-- ASCII / plain-text renderer for organ.nvim AST.
--
-- Produces a faithful but bare rendition: headlines underlined with
-- `= - ~ . _`, emphasis markers stripped (content preserved), links
-- shown as `text (url)`, inline images/footnote_refs dropped, math
-- rendered as raw body text.

local A = require("organ.ast")
local ENTITIES = require("organ.ast.org_entities")
local links = require("organ.ast.links")
local OPTIONS = require("organ.export.options")

local M = {}

local emit_inline
local emit_block
local emit_toc_keyword
-- The document being rendered, and the headline a `#+TOC: ... local`
-- sits under while its section emits.
local _doc
local _toc_scope

local UNDERLINES = { "=", "-", "~", ".", "_" }

-- org-ascii-text-width: the column tags are flushed against.
local TEXT_WIDTH = 72

-- Resolved export options, outline counters, caption sequence numbers.
local _o = OPTIONS.defaults()
local _secno = {}
local _ordinal = {}

local function affiliated(node, name)
  for _, a in ipairs(node.affiliated or {}) do
    if a.name == name then
      return a
    end
  end
end

-- `strdisplaywidth` raises E976 on a string holding a NUL byte, which
-- Vimscript takes for a Blob.  nvim renders that byte as `^@`.
local function cell_width(s)
  return vim.fn.strdisplaywidth((s:gsub("%z", "^@")))
end

function emit_inline(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "emphasis" then
      out[#out + 1] = emit_inline(n.content)
    elseif n.kind == "radio_target" then
      out[#out + 1] = n.phrase or ""
    elseif n.kind == "link" then
      if n.form == "radio" then
        out[#out + 1] = emit_inline(n.description)
      else
        local target = n.target or ""
        if n.description and #n.description > 0 then
          out[#out + 1] = emit_inline(n.description) .. " (" .. target .. ")"
        else
          out[#out + 1] = target
        end
      end
    elseif n.kind == "math" then
      -- ox-ascii prints a fragment verbatim, delimiters included.
      local body = n.body or ""
      if n.style == "paren" then
        out[#out + 1] = "\\(" .. body .. "\\)"
      elseif n.style == "bracket" then
        out[#out + 1] = "\\[" .. body .. "\\]"
      elseif n.display then
        out[#out + 1] = "$$" .. body .. "$$"
      else
        out[#out + 1] = "$" .. body .. "$"
      end
    elseif n.kind == "image" then
      if n.alt and n.alt ~= "" then
        out[#out + 1] = n.alt .. " (" .. (n.target or "") .. ")"
      else
        out[#out + 1] = "<" .. (n.target or "") .. ">"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "\n"
    elseif n.kind == "subscript" then
      out[#out + 1] = "_" .. emit_inline(n.content)
    elseif n.kind == "superscript" then
      out[#out + 1] = "^" .. emit_inline(n.content)
    elseif n.kind == "entity" then
      -- `\alpha{}` names the same entity as `\alpha`; the braces only
      -- terminate the name.
      local name = (n.name or ""):gsub("{}$", "")
      local e = ENTITIES[name]
      out[#out + 1] = e and e.ascii or ("\\" .. name)
    elseif n.kind == "statistics_cookie" or n.kind == "timestamp" then
      out[#out + 1] = n.value or ""
    elseif n.kind == "macro" then
      local args = (n.args and #n.args > 0) and ("(" .. table.concat(n.args, ",") .. ")") or ""
      out[#out + 1] = "{{{" .. (n.name or "") .. args .. "}}}"
    elseif n.kind == "raw_inline" then
      out[#out + 1] = n.text or ""
    end
    -- footnote_ref / target intentionally drop (no ascii syntax)
  end
  local s = table.concat(out)
  local ok, cite = pcall(require, "organ.cite")
  if ok and type(cite.replace_in) == "function" then
    s = cite.replace_in(s, "ascii")
  end
  return s
end

local function section_number(level)
  _secno[level] = (_secno[level] or 0) + 1
  for i = level + 1, #_secno do
    _secno[i] = nil
  end
  local parts = {}
  for i = 1, level do
    parts[#parts + 1] = tostring(_secno[i] or 0)
  end
  return table.concat(parts, ".")
end

-- org-ascii--build-title: number and TODO keyword lead, tags are
-- flushed right against `org-ascii-text-width`.
local function headline_line(node, number)
  local parts = {}
  if number then
    parts[#parts + 1] = number .. " "
  end
  if _o.with_todo_keywords and node.todo and node.todo ~= "" then
    parts[#parts + 1] = node.todo .. " "
  end
  if _o.with_priority and node.priority and node.priority ~= "" then
    parts[#parts + 1] = "(#" .. node.priority .. ") "
  end
  parts[#parts + 1] = emit_inline(node.title)
  local line = table.concat(parts)
  local width = cell_width(line)
  if _o.with_tags and node.tags and #node.tags > 0 then
    local tags = ":" .. table.concat(node.tags, ":") .. ":"
    local pad = TEXT_WIDTH - width - cell_width(tags)
    line = line .. string.rep(" ", math.max(1, pad)) .. tags
  end
  -- The rule underlines the title, not the flushed-right tags.
  return line, width
end

local function emit_planning(node, out)
  local p = node.planning
  if not (_o.with_planning and p) then
    return
  end
  local parts = {}
  for _, k in ipairs({ "closed", "deadline", "scheduled" }) do
    if p[k] then
      parts[#parts + 1] = k:upper() .. ": " .. p[k]
    end
  end
  if #parts > 0 then
    out[#out + 1] = table.concat(parts, " ")
    out[#out + 1] = ""
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
  local n = #out
  for _, k in ipairs(keys) do
    if wanted_property(k) then
      out[#out + 1] = k .. ": " .. node.properties[k]
    end
  end
  if #out > n then
    out[#out + 1] = ""
  end
end

-- ox.el `org-export-low-level-p`: `#+OPTIONS: H:N` renders a headline
-- deeper than N as a list item rather than as an underlined title.
local function low_level(n)
  return n.kind == "headline"
    and type(_o.headline_levels) == "number"
    and (n.level or 1) > _o.headline_levels
end

-- Rewrite each run of demoted headline siblings into one list node, so
-- the ordinary list emitter handles markers and indentation.  ox-ascii
-- bullets a demoted headline whether or not it is numbered, keeping the
-- section number inside the title.  Titles are built here because the
-- outline counter must advance in document order.
local function demote(children)
  local out, i, n = {}, 1, #children
  while i <= n do
    if low_level(children[i]) then
      local items = {}
      while i <= n and low_level(children[i]) do
        local h = children[i]
        local number = _o.with_section_numbers and section_number(h.level or 1) or nil
        local content = { A.paragraph({ A.raw_inline((headline_line(h, number))) }) }
        for _, b in ipairs(demote(h.children or {})) do
          content[#content + 1] = b
        end
        items[#items + 1] = A.list_item({ content = content })
        i = i + 1
      end
      out[#out + 1] = A.list(false, items)
    else
      out[#out + 1] = children[i]
      i = i + 1
    end
  end
  return out
end

local function emit_headline(node, out)
  local level = node.level or 1
  local number = _o.with_section_numbers and section_number(level) or nil
  local line, width = headline_line(node, number)
  out[#out + 1] = line
  -- Cycle the underline set so a level past its end still gets a rule.
  local u = UNDERLINES[(level - 1) % #UNDERLINES + 1]
  out[#out + 1] = string.rep(u, math.max(1, width))
  out[#out + 1] = ""
  emit_planning(node, out)
  emit_properties(node, out)
  local outer = _toc_scope
  _toc_scope = node
  for _, c in ipairs(demote(node.children or {})) do
    emit_block(c, out)
  end
  _toc_scope = outer
end

local function emit_paragraph(node, out)
  out[#out + 1] = emit_inline(node.inline)
  out[#out + 1] = ""
end

local function emit_list(node, out, depth)
  depth = depth or 0
  local indent = string.rep("  ", depth)
  local n = 0
  for _, item in ipairs(node.items or {}) do
    n = n + 1
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = "[ ] "
    elseif item.checkbox == "done" then
      checkbox = "[X] "
    elseif item.checkbox == "part" then
      checkbox = "[-] "
    end
    local marker = node.ordered and (n .. ".") or "-"
    local cont = indent .. string.rep(" ", #marker + 1)
    -- `- term :: definition`: ox-ascii puts the term on its own line.
    if item.tag then
      out[#out + 1] = indent .. emit_inline(item.tag)
      marker, cont = nil, indent .. "  "
    end
    local first = marker ~= nil
    for _, b in ipairs(item.content or {}) do
      if b.kind == "paragraph" then
        local txt = emit_inline(b.inline)
        if first then
          out[#out + 1] = indent .. marker .. " " .. checkbox .. txt
          first = false
        else
          out[#out + 1] = cont .. txt
        end
      elseif b.kind == "list" then
        if first then
          out[#out + 1] = (indent .. marker .. " " .. checkbox):gsub("%s+$", "")
          first = false
        end
        emit_list(b, out, depth + 1)
      else
        -- Anything else in the item -- a src block, table, quote --
        -- renders into a sub-buffer and is indented under the marker.
        if first then
          out[#out + 1] = (indent .. marker .. " " .. checkbox):gsub("%s+$", "")
          first = false
        end
        local sub = {}
        emit_block(b, sub)
        while #sub > 0 and sub[#sub] == "" do
          sub[#sub] = nil
        end
        for _, l in ipairs(sub) do
          out[#out + 1] = l == "" and "" or (cont .. l)
        end
      end
    end
    if first then
      out[#out + 1] = (indent .. marker .. " " .. checkbox):gsub("%s+$", "")
    end
  end
  out[#out + 1] = ""
end

local function ordinal(kind)
  _ordinal[kind] = (_ordinal[kind] or 0) + 1
  return _ordinal[kind]
end

-- ox-ascii prints the caption on its own line under the element.
local function emit_caption(node, kind, out)
  local a = affiliated(node, "CAPTION")
  if not a then
    return
  end
  local label = kind:sub(1, 1):upper() .. kind:sub(2)
  out[#out + 1] = label
    .. " "
    .. ordinal(kind)
    .. ": "
    .. (a.inline and emit_inline(a.inline) or (a.value or ""))
end

local function emit_indented(body, out)
  for line in ((body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = "    " .. line
  end
  if out[#out] == "    " then
    out[#out] = nil
  end
  out[#out + 1] = ""
end

-- ox-ascii boxes verbatim text -- fixed-width lines, example blocks and
-- source blocks alike -- so it stays distinguishable from surrounding
-- prose.  A source block's language is not shown.
local function emit_boxed(body, out)
  out[#out + 1] = ",----"
  for line in ((body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = "| " .. line
  end
  if out[#out] == "| " then
    out[#out] = nil
  end
  out[#out + 1] = "`----"
  out[#out + 1] = ""
end

local function emit_code_block(node, out)
  emit_boxed(node.body, out)
  local n = #out
  emit_caption(node, "listing", out)
  if #out > n then
    out[#out + 1] = ""
  end
end

local function emit_fixed_width(node, out)
  emit_boxed(node.body, out)
end

local function emit_latex_environment(node, out)
  if not _o.with_latex then
    return
  end
  for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = ""
end

local function emit_org_block(node, out)
  local style = node.style
  if style == "example" then
    emit_boxed(node.body, out)
  elseif style == "verse" then
    if node.content then
      local sub = {}
      for _, b in ipairs(node.content) do
        if b.kind == "paragraph" then
          sub[#sub + 1] = emit_inline(b.inline)
        else
          emit_block(b, sub)
        end
      end
      emit_indented(table.concat(sub, "\n"), out)
    else
      emit_indented(node.body, out)
    end
  elseif style == "center" then
    local sub = {}
    for _, b in ipairs(node.content or {}) do
      emit_block(b, sub)
    end
    while #sub > 0 and sub[#sub] == "" do
      sub[#sub] = nil
    end
    for _, l in ipairs(sub) do
      local pad = math.floor((TEXT_WIDTH - cell_width(l)) / 2)
      out[#out + 1] = l == "" and "" or (string.rep(" ", math.max(0, pad)) .. l)
    end
    out[#out + 1] = ""
  elseif style == "export" then
    if (node.backend or ""):lower() == "ascii" then
      for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
      if out[#out] == "" then
        out[#out] = nil
      end
      out[#out + 1] = ""
    end
  elseif style == "quote" then
    -- Render content into a sub-buffer, then prefix each line with "  > ".
    local sub = {}
    for _, b in ipairs(node.content or {}) do
      emit_block(b, sub)
    end
    while #sub > 0 and sub[#sub] == "" do
      sub[#sub] = nil
    end
    for _, line in ipairs(sub) do
      if line == "" then
        out[#out + 1] = "  >"
      else
        out[#out + 1] = "  > " .. line
      end
    end
    out[#out + 1] = ""
  elseif node.content then
    -- Any other greater block: ox-ascii keeps its contents and drops the
    -- wrapper, which has no plain-text form.
    for _, b in ipairs(node.content) do
      emit_block(b, out)
    end
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

local function emit_table(node, out)
  local rows = {}
  for _, r in ipairs(node.rows or {}) do
    if not special_row(r) then
      rows[#rows + 1] = r
    end
  end
  -- Compute ncols from widest non-sep row.
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

  -- Render each non-sep cell into a plain string; collect for width pass.
  local rendered = {}
  for i, r in ipairs(rows) do
    if r.sep then
      rendered[i] = { sep = true }
    else
      local cells = {}
      for c = 1, ncols do
        cells[c] = emit_inline(r.cells[c] or {})
      end
      rendered[i] = { sep = false, cells = cells }
    end
  end

  -- Compute per-column max width (display width).
  local widths = {}
  for c = 1, ncols do
    widths[c] = 0
  end
  for _, r in ipairs(rendered) do
    if not r.sep then
      for c = 1, ncols do
        local w = cell_width(r.cells[c] or "")
        if w > widths[c] then
          widths[c] = w
        end
      end
    end
  end

  local function divider()
    local parts = {}
    for c = 1, ncols do
      parts[c] = string.rep("-", widths[c] + 2)
    end
    return "+" .. table.concat(parts, "+") .. "+"
  end

  local function row_line(cells)
    local parts = {}
    for c = 1, ncols do
      local cell = cells[c] or ""
      parts[c] = " " .. cell .. string.rep(" ", widths[c] - cell_width(cell)) .. " "
    end
    return "|" .. table.concat(parts, "|") .. "|"
  end

  out[#out + 1] = divider()
  for _, r in ipairs(rendered) do
    if r.sep then
      out[#out + 1] = divider()
    else
      out[#out + 1] = row_line(r.cells)
    end
  end
  out[#out + 1] = divider()
  emit_caption(node, "table", out)
  out[#out + 1] = ""
end

-- A block-level image: ox-ascii prints the path, or the description
-- and the path when the link carried one.
local function emit_image_block(node, out)
  if node.alt and node.alt ~= "" then
    out[#out + 1] = node.alt .. " (" .. (node.target or "") .. ")"
  else
    out[#out + 1] = "<" .. (node.target or "") .. ">"
  end
  emit_caption(node, "figure", out)
  out[#out + 1] = ""
end

local function emit_rule(_, out)
  out[#out + 1] = string.rep("-", 60)
  out[#out + 1] = ""
end

local function emit_footnote_definition(node, out)
  local first_body = ""
  if node.content and node.content[1] and node.content[1].kind == "paragraph" then
    first_body = emit_inline(node.content[1].inline)
  end
  out[#out + 1] = "[" .. (node.label or "") .. "] " .. first_body
  if node.content and #node.content > 1 then
    for i = 2, #node.content do
      local b = node.content[i]
      if b.kind == "paragraph" then
        out[#out + 1] = "    " .. emit_inline(b.inline)
      end
    end
  end
  out[#out + 1] = ""
end

function emit_block(node, out)
  if not node or not node.kind then
    return
  end
  local kind = node.kind
  if kind == "document" then
    for _, c in ipairs(demote(node.children or {})) do
      emit_block(c, out)
    end
  elseif kind == "headline" then
    emit_headline(node, out)
  elseif kind == "paragraph" then
    emit_paragraph(node, out)
  elseif kind == "list" then
    emit_list(node, out, 0)
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
  elseif kind == "footnote_definition" then
    emit_footnote_definition(node, out)
  elseif kind == "directive" and (node.name or ""):upper() == "TOC" then
    emit_toc_keyword(node.value or "", out)
  end
  -- other kinds (other directives, drawer, comment, ...): silently drop.
  -- ASCII has no syntax for them and they would be noise in a
  -- plain-text rendition.
end

-- ox-ascii's table of contents: `1. Title`, deeper levels prefixed with
-- a dotted rule.
-- `scope` is the headline a local TOC covers (nil for the whole
-- document); a local TOC is the bare list, with no title above it.
local function emit_toc_list(scope, out, depth, bare)
  local entries, counters = {}, {}
  local function walk(nodes)
    for _, c in ipairs(nodes or {}) do
      if c.kind == "headline" then
        local l = c.level or 1
        counters[l] = (counters[l] or 0) + 1
        for i = l + 1, #counters do
          counters[i] = nil
        end
        if l <= depth then
          entries[#entries + 1] = { level = l, number = counters[l], node = c }
        end
        walk(c.children)
      end
    end
  end
  walk(scope.children)
  if #entries == 0 then
    return
  end
  -- ox-ascii indents a local TOC by the headline's absolute level, not
  -- relative to the scope.
  local base = bare and 1 or entries[1].level
  for _, e in ipairs(entries) do
    if not bare and e.level < base then
      base = e.level
    end
  end
  if not bare then
    out[#out + 1] = "Table of Contents"
    out[#out + 1] = string.rep("_", 17)
    out[#out + 1] = ""
  end
  for _, e in ipairs(entries) do
    local prefix = string.rep("..", e.level - base)
    out[#out + 1] = (prefix == "" and "" or (prefix .. " "))
      .. e.number
      .. ". "
      .. emit_inline(e.node.title)
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

-- Every captioned node of `kind`, numbered as the body numbers them.
local function emit_caption_list(kind, title, out)
  local want = ({ table = "table", listing = "code_block", figure = "image" })[kind]
  local label = kind:sub(1, 1):upper() .. kind:sub(2)
  local lines = {}
  A.walk(_doc, function(n)
    local a = n.kind == want and affiliated(n, "CAPTION")
    if a then
      lines[#lines + 1] = label
        .. " "
        .. (#lines + 1)
        .. ": "
        .. (a.inline and emit_inline(a.inline) or (a.value or ""))
    end
  end)
  if #lines == 0 then
    return
  end
  out[#out + 1] = title
  out[#out + 1] = string.rep("_", #title)
  out[#out + 1] = ""
  for _, l in ipairs(lines) do
    out[#out + 1] = l
  end
  out[#out + 1] = ""
end

-- org-ascii-keyword: `#+TOC: headlines N [local]`, `tables`, `listings`.
-- `figures` is accepted and, as in ox-ascii, renders nothing.
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
    emit_caption_list("table", "List of Tables", out)
  elseif v:find("listings") then
    emit_caption_list("listing", "List of Listings", out)
  end
end

function M.render(ast, _opts)
  if not ast then
    return ""
  end
  _o = (ast.kind == "document" and ast.options) or OPTIONS.defaults()
  _secno, _ordinal = {}, {}
  _doc, _toc_scope = ast, nil
  local out = {}
  if ast.kind == "document" then
    emit_toc(ast, out)
  end
  emit_block(ast, out)
  -- Trim trailing blanks but ensure a final newline.
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return table.concat(out, "\n") .. "\n"
end

M._emit_inline = emit_inline
M._emit_block = emit_block

return M
