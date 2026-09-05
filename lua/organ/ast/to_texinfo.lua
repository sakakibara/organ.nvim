-- Document AST -> GNU Texinfo (.texi) string.
--
-- Companion to from_org.lua.  Emits a complete Texinfo document
-- (preamble + @titlepage + body + @bye) wrapping a body rendered
-- from the AST.  Headlines map to @chapter / @section / @subsection
-- / @subsubsection; levels beyond 4 collapse to @subsubsection.
-- @node lines are emitted to satisfy `info` navigation; the
-- prev/next/up fields are inferred by texinfo or by post-processing.

local A = require("organ.ast")
local ENTITIES = require("organ.ast.org_entities")
local links = require("organ.ast.links")
local OPTIONS = require("organ.export.options")

local M = {}

-- Resolved export options.
local _o = OPTIONS.defaults()

local function affiliated(node, name)
  for _, a in ipairs(node.affiliated or {}) do
    if a.name == name then
      return a
    end
  end
end

-- org-texinfo-entity: Texinfo commands where they exist, UTF-8 otherwise.
local ENTITY_CMD = {
  AElig = "@AE{}",
  aelig = "@ae{}",
  bull = "@bullet{}",
  bullet = "@bullet{}",
  copy = "@copyright{}",
  deg = "@textdegree{}",
  dots = "@dots{}",
  hellip = "@dots{}",
  equiv = "@equiv{}",
  euro = "@euro{}",
  EUR = "@euro{}",
  ge = "@geq{}",
  geq = "@geq{}",
  laquo = "@guillemetleft{}",
  iexcl = "@exclamdown{}",
  imath = "@dotless{i}",
  iquest = "@questiondown{}",
  jmath = "@dotless{j}",
  le = "@leq{}",
  leq = "@leq{}",
  lsaquo = "@guilsinglleft{}",
  mdash = "---",
  minus = "@minus{}",
  nbsp = "@tie{}",
  ndash = "--",
  OElig = "@OE{}",
  oelig = "@oe{}",
  ordf = "@ordf{}",
  ordm = "@ordm{}",
  pound = "@pound{}",
  raquo = "@guillemetright{}",
  rArr = "@result{}",
  Rightarrow = "@result{}",
  reg = "@registeredsymbol{}",
  rightarrow = "@arrow{}",
  to = "@arrow{}",
  rarr = "@arrow{}",
  rsaquo = "@guilsinglright{}",
  thorn = "@th{}",
  THORN = "@TH{}",
}

local SECT = {
  [1] = "@chapter",
  [2] = "@section",
  [3] = "@subsection",
  [4] = "@subsubsection",
}

-- Texinfo escape: { } @ are special.  This is the full escape set for
-- prose; @code{}/@math{} bodies still need {} escaped so command
-- nesting stays balanced.
local function escape_text(s)
  if not s then
    return ""
  end
  s = s:gsub("@", "@@")
  s = s:gsub("{", "@{")
  s = s:gsub("}", "@}")
  return s
end

local emit_inline
local emit_block

function emit_inline(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = escape_text(n.text or "")
    elseif n.kind == "emphasis" then
      local inner = emit_inline(n.content)
      local s = n.style
      if s == "bold" then
        out[#out + 1] = "@strong{" .. inner .. "}"
      elseif s == "italic" then
        out[#out + 1] = "@emph{" .. inner .. "}"
      elseif s == "underline" then
        out[#out + 1] = "@sansserif{" .. inner .. "}"
      elseif s == "strike" then
        out[#out + 1] = "@strikethrough{" .. inner .. "}"
      elseif s == "verbatim" or s == "code" then
        out[#out + 1] = "@code{" .. inner .. "}"
      else
        out[#out + 1] = inner
      end
    elseif n.kind == "radio_target" then
      out[#out + 1] = escape_text(n.phrase or "")
    elseif n.kind == "link" then
      if n.form == "radio" then
        out[#out + 1] = emit_inline(n.description)
      else
        local target = n.target or ""
        if n.description and #n.description > 0 then
          out[#out + 1] = "@uref{" .. target .. ", " .. emit_inline(n.description) .. "}"
        else
          out[#out + 1] = "@uref{" .. target .. "}"
        end
      end
    elseif n.kind == "image" then
      if n.alt and n.alt ~= "" then
        -- A described link is a hyperlink, never an inline image.
        out[#out + 1] = "@uref{" .. (n.target or "") .. ", " .. escape_text(n.alt) .. "}"
      end
      -- Texinfo's @image is block-level only; drop undescribed ones.
    elseif n.kind == "footnote_ref" then
      -- Proper @ref/@anchor wiring lands with footnote_definition support;
      -- emit a literal label fallback for now.
      out[#out + 1] = "[" .. (n.label or "") .. "]"
    elseif n.kind == "math" then
      -- Texinfo has no inline-vs-display distinction; @math{} handles both.
      out[#out + 1] = "@math{" .. (n.body or "") .. "}"
    elseif n.kind == "linebreak" then
      out[#out + 1] = "@*"
    elseif n.kind == "subscript" then
      out[#out + 1] = "@math{_" .. emit_inline(n.content) .. "}"
    elseif n.kind == "superscript" then
      out[#out + 1] = "@math{^" .. emit_inline(n.content) .. "}"
    elseif n.kind == "entity" then
      -- `\alpha{}` names the same entity as `\alpha`; the braces only
      -- terminate the name.
      local name = (n.name or ""):gsub("{}$", "")
      local e = ENTITIES[name]
      if ENTITY_CMD[name] then
        out[#out + 1] = ENTITY_CMD[name]
      elseif e and name:sub(1, 1) == "_" then
        out[#out + 1] = "@w{" .. name:sub(2) .. "}"
      elseif e then
        out[#out + 1] = escape_text(e.utf8)
      else
        out[#out + 1] = escape_text("\\" .. name)
      end
    elseif n.kind == "statistics_cookie" then
      out[#out + 1] = escape_text(n.value)
    elseif n.kind == "timestamp" then
      out[#out + 1] = "@emph{" .. escape_text(n.value) .. "}"
    elseif n.kind == "target" then
      out[#out + 1] = "@anchor{" .. escape_text(n.name) .. "}"
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
    s = cite.replace_in(s, "texinfo")
  end
  return s
end

-- TODO keyword, priority cookie and tags each get their own markup
-- around the title (org-texinfo-headline).
local function headline_title(node)
  local parts = {}
  if _o.with_todo_keywords and node.todo and node.todo ~= "" then
    parts[#parts + 1] = "@strong{" .. escape_text(node.todo) .. "} "
  end
  if _o.with_priority and node.priority and node.priority ~= "" then
    parts[#parts + 1] = "@emph{#" .. escape_text(node.priority) .. "} "
  end
  parts[#parts + 1] = emit_inline(node.title or {})
  if _o.with_tags and node.tags and #node.tags > 0 then
    parts[#parts + 1] = " :" .. escape_text(table.concat(node.tags, ":")) .. ":"
  end
  return table.concat(parts)
end

-- ox.el `org-export-low-level-p`: `#+OPTIONS: H:N` renders a headline
-- deeper than N as a list item rather than as a sectioning command.  A
-- demoted headline is not a node, so it keeps an @anchor instead.
local function low_level(n)
  return n.kind == "headline"
    and type(_o.headline_levels) == "number"
    and (n.level or 1) > _o.headline_levels
end

-- ox.el `org-export-numbered-headline-p`: `num:N` numbers only the first
-- N levels, so a deeper headline demotes to an @itemize.
local function numbered(n)
  local sec = _o.with_section_numbers
  if type(sec) == "number" then
    return (n.level or 1) <= sec
  end
  return not not sec
end

-- Rewrite each run of demoted headline siblings into one list node, so
-- the ordinary list emitter handles the environment and nesting.
local function demote(children)
  local out, i, n = {}, 1, #children
  while i <= n do
    if low_level(children[i]) then
      local items = {}
      local first = children[i]
      while i <= n and low_level(children[i]) do
        local h = children[i]
        local head = "@anchor{" .. emit_inline(h.title or {}) .. "}" .. headline_title(h)
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

local function emit_headline(node, out)
  local level = node.level or 1
  local cmd = SECT[math.min(level, 4)] or "@subsubsection"
  local title = headline_title(node)
  out[#out + 1] = "@node " .. emit_inline(node.title or {})
  out[#out + 1] = cmd .. " " .. title
  out[#out + 1] = ""
  for _, c in ipairs(demote(node.children or {})) do
    emit_block(c, out)
  end
end

local function emit_paragraph(node, out)
  out[#out + 1] = emit_inline(node.inline or {})
  out[#out + 1] = ""
end

local function emit_list(node, out)
  local items = node.items or {}
  -- `- term :: definition` is Texinfo's two-column @table.
  local described = items[1] and items[1].tag ~= nil
  local env = described and "@table @asis" or (node.ordered and "@enumerate" or "@itemize")
  out[#out + 1] = env
  for _, item in ipairs(items) do
    if described then
      out[#out + 1] = "@item " .. emit_inline(item.tag or {})
    end
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = "[ ] "
    elseif item.checkbox == "done" then
      checkbox = "[X] "
    elseif item.checkbox == "part" then
      checkbox = "[-] "
    end
    local first = not described
    for _, b in ipairs(item.content or {}) do
      if b.kind == "paragraph" then
        if first then
          out[#out + 1] = "@item " .. checkbox .. emit_inline(b.inline)
          first = false
        else
          out[#out + 1] = emit_inline(b.inline)
        end
      elseif b.kind == "list" then
        emit_list(b, out)
      else
        if first then
          out[#out + 1] = ("@item " .. checkbox):gsub("%s+$", "")
          first = false
        end
        emit_block(b, out)
      end
    end
    if first and checkbox ~= "" then
      out[#out + 1] = "@item " .. checkbox
    elseif first then
      out[#out + 1] = "@item"
    end
  end
  out[#out + 1] = "@end " .. env:sub(2):match("^%a+")
  out[#out + 1] = ""
end

local function emit_code_block(node, out)
  out[#out + 1] = "@example"
  for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = "@end example"
  out[#out + 1] = ""
end

local function emit_fixed_width(node, out)
  emit_code_block({ body = node.body }, out)
end

local function emit_latex_environment(node, out)
  if not _o.with_latex then
    return
  end
  if _o.with_latex == "verbatim" then
    emit_code_block({ body = node.body }, out)
    return
  end
  out[#out + 1] = "@displaymath"
  for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = "@end displaymath"
  out[#out + 1] = ""
end

local function emit_org_block(node, out)
  local style = node.style
  if style == "example" then
    emit_code_block({ body = node.body }, out)
  elseif style == "verse" then
    -- Verse keeps its inline markup; @display preserves the line breaks.
    out[#out + 1] = "@display"
    if node.content then
      local sub = {}
      for _, b in ipairs(node.content) do
        if b.kind == "paragraph" then
          sub[#sub + 1] = emit_inline(b.inline)
        else
          emit_block(b, sub)
        end
      end
      for line in (table.concat(sub, "\n") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
    else
      for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
    end
    if out[#out] == "" then
      out[#out] = nil
    end
    out[#out + 1] = "@end display"
    out[#out + 1] = ""
  elseif style == "quote" then
    out[#out + 1] = "@quotation"
    for _, b in ipairs(node.content or {}) do
      emit_block(b, out)
    end
    out[#out + 1] = "@end quotation"
    out[#out + 1] = ""
  elseif style == "center" then
    local sub = {}
    for _, b in ipairs(node.content or {}) do
      emit_block(b, sub)
    end
    while #sub > 0 and sub[#sub] == "" do
      sub[#sub] = nil
    end
    for _, l in ipairs(sub) do
      out[#out + 1] = "@center " .. l
    end
    out[#out + 1] = ""
  elseif style == "export" then
    if (node.backend or ""):lower() == "texinfo" then
      for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
      if out[#out] == "" then
        out[#out] = nil
      end
      out[#out + 1] = ""
    end
  elseif node.content then
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

  local fracs = {}
  for i = 1, ncols do
    fracs[i] = string.format(".%d", math.floor(100 / ncols))
  end
  out[#out + 1] = "@multitable @columnfractions " .. table.concat(fracs, " ")

  for _, r in ipairs(rows) do
    if not r.sep then
      local cells = {}
      for c = 1, ncols do
        cells[c] = emit_inline(r.cells[c] or {})
      end
      out[#out + 1] = "@item " .. table.concat(cells, " @tab ")
    end
    -- sep rows are dropped
  end

  out[#out + 1] = "@end multitable"
  out[#out + 1] = ""
end

local function emit_image_block(node, out)
  local target = node.target or ""
  if node.alt and node.alt ~= "" then
    -- A described link is a hyperlink, never an image.
    out[#out + 1] = "@uref{" .. target .. ", " .. escape_text(node.alt) .. "}"
    out[#out + 1] = ""
    return
  end
  local cap = affiliated(node, "CAPTION")
  if cap then
    out[#out + 1] = "@float Figure"
    out[#out + 1] = "@image{" .. target .. "}"
    out[#out + 1] = "@caption{"
      .. (cap.inline and emit_inline(cap.inline) or escape_text(cap.value))
      .. "}"
    out[#out + 1] = "@end float"
  else
    out[#out + 1] = "@image{" .. target .. "}"
  end
  out[#out + 1] = ""
end

local function emit_rule(_, out)
  out[#out + 1] = "@page"
  out[#out + 1] = ""
end

local function emit_footnote_definition(node, out)
  local label = node.label or ""
  local first_body = ""
  if node.content and node.content[1] and node.content[1].kind == "paragraph" then
    first_body = emit_inline(node.content[1].inline)
  end
  out[#out + 1] = "[" .. label .. "] " .. first_body
  if node.content and #node.content > 1 then
    for i = 2, #node.content do
      local b = node.content[i]
      if b.kind == "paragraph" then
        out[#out + 1] = emit_inline(b.inline)
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
  elseif kind == "footnote_definition" then
    emit_footnote_definition(node, out)
  elseif kind == "directive" and (node.name or ""):upper() == "TOC" then
    -- org-texinfo-keyword: only `tables` and `listings`; `headlines` is
    -- covered by @menu, and `figures` renders nothing.
    local v = (node.value or ""):lower()
    if v:find("tables") then
      out[#out + 1] = "@listoffloats Table"
      out[#out + 1] = ""
    elseif v:find("listings") then
      out[#out + 1] = "@listoffloats Listing"
      out[#out + 1] = ""
    end
  end
  -- directive, drawer, comment and unknown kinds drop silently.
end

local function find_directive(ast, name)
  if not ast or not ast.children then
    return nil
  end
  for _, c in ipairs(ast.children) do
    if c.kind == "directive" and c.name == name then
      return c.value
    end
  end
  return nil
end

function M.render(ast, opts)
  if not ast then
    return ""
  end
  opts = opts or {}
  _o = (ast.kind == "document" and ast.options) or OPTIONS.defaults()
  local body = {}
  emit_block(ast, body)
  if opts.body_only then
    return table.concat(body, "\n") .. "\n"
  end
  local title = find_directive(ast, "TITLE") or "Untitled"
  local author = find_directive(ast, "AUTHOR")
  local filename = find_directive(ast, "FILENAME") or (title:gsub("%s+", "_") .. ".info")
  local doc = {
    [[\input texinfo @c -*-texinfo-*-]],
    "@c %**start of header",
    "@setfilename " .. filename,
    "@settitle " .. escape_text(title),
    "@c %**end of header",
    "",
    "@titlepage",
    "@title " .. escape_text(title),
  }
  if author then
    doc[#doc + 1] = "@author " .. escape_text(author)
  end
  doc[#doc + 1] = "@end titlepage"
  doc[#doc + 1] = ""
  doc[#doc + 1] = "@contents"
  doc[#doc + 1] = ""
  for _, l in ipairs(body) do
    doc[#doc + 1] = l
  end
  doc[#doc + 1] = "@bye"
  return table.concat(doc, "\n") .. "\n"
end

-- Expose internals for tests.
M._emit_inline = emit_inline
M._emit_block = emit_block
M._escape_text = escape_text

return M
