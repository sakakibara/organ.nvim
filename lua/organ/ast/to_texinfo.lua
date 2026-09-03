-- Document AST -> GNU Texinfo (.texi) string.
--
-- Companion to from_org.lua.  Emits a complete Texinfo document
-- (preamble + @titlepage + body + @bye) wrapping a body rendered
-- from the AST.  Headlines map to @chapter / @section / @subsection
-- / @subsubsection; levels beyond 4 collapse to @subsubsection.
-- @node lines are emitted to satisfy `info` navigation; the
-- prev/next/up fields are inferred by texinfo or by post-processing.

local ENTITIES = require("organ.ast.org_entities")

local M = {}

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
      -- Texinfo's @image is block-level only; drop inline images.
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
      local name = n.name or ""
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

local function emit_headline(node, out)
  local level = node.level or 1
  local cmd = SECT[math.min(level, 4)] or "@subsubsection"
  local title = emit_inline(node.title or {})
  out[#out + 1] = "@node " .. title
  out[#out + 1] = cmd .. " " .. title
  out[#out + 1] = ""
  for _, c in ipairs(node.children or {}) do
    emit_block(c, out)
  end
end

local function emit_paragraph(node, out)
  out[#out + 1] = emit_inline(node.inline or {})
  out[#out + 1] = ""
end

local function emit_list(node, out)
  local env = node.ordered and "@enumerate" or "@itemize"
  out[#out + 1] = env
  for _, item in ipairs(node.items or {}) do
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = "[ ] "
    elseif item.checkbox == "done" then
      checkbox = "[X] "
    elseif item.checkbox == "part" then
      checkbox = "[-] "
    end
    local first = true
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
      end
    end
    if first and checkbox ~= "" then
      out[#out + 1] = "@item " .. checkbox
    elseif first then
      out[#out + 1] = "@item"
    end
  end
  out[#out + 1] = "@end " .. env:sub(2)
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

local function emit_org_block(node, out)
  local style = node.style
  if style == "example" or style == "verse" then
    emit_code_block({ body = node.body }, out)
  elseif style == "quote" then
    out[#out + 1] = "@quotation"
    for _, b in ipairs(node.content or {}) do
      emit_block(b, out)
    end
    out[#out + 1] = "@end quotation"
    out[#out + 1] = ""
  end
  -- export and unknown styles drop silently
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
    out[#out + 1] = "@image{" .. target .. ", , , " .. escape_text(node.alt) .. "}"
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
