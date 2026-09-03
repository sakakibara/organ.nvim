-- Document AST -> LaTeX string.
--
-- Companion to from_org.lua.  Emits a complete `article` document
-- (preamble + \begin{document} ... \end{document}) wrapping a body
-- rendered from the AST.  Inline math regions pass through verbatim;
-- the body of \verb spans skips the special-char escape table since
-- \verb provides its own no-escape semantics.

local A = require("organ.ast")
local links = require("organ.ast.links")
local ENTITIES = require("organ.ast.org_entities")

local M = {}

-- Sectioning commands by headline level.  Beyond L5 we collapse to
-- \subparagraph to match Emacs `org-latex-classes` "article" defaults.
local SECTION_CMDS = {
  [1] = "\\section",
  [2] = "\\subsection",
  [3] = "\\subsubsection",
  [4] = "\\paragraph",
  [5] = "\\subparagraph",
}

-- Escape a span of plain text into LaTeX.  Two-phase: every special
-- becomes a placeholder, then placeholders become their LaTeX form.
-- This prevents the second pass from re-escaping characters introduced
-- by the first (e.g. the `{` in `\textbackslash{}`).
local PLACEHOLDERS = {
  ["\\"] = "\1bs\1",
  ["&"] = "\1amp\1",
  ["%"] = "\1pct\1",
  ["$"] = "\1dol\1",
  ["#"] = "\1hsh\1",
  ["_"] = "\1usc\1",
  ["{"] = "\1lbr\1",
  ["}"] = "\1rbr\1",
  ["~"] = "\1tld\1",
  ["^"] = "\1crt\1",
  ["<"] = "\1lt\1",
  [">"] = "\1gt\1",
}
local PLACEHOLDER_TO_TEX = {
  ["\1bs\1"] = "\\textbackslash{}",
  ["\1amp\1"] = "\\&",
  ["\1pct\1"] = "\\%",
  ["\1dol\1"] = "\\$",
  ["\1hsh\1"] = "\\#",
  ["\1usc\1"] = "\\_",
  ["\1lbr\1"] = "\\{",
  ["\1rbr\1"] = "\\}",
  ["\1tld\1"] = "\\textasciitilde{}",
  ["\1crt\1"] = "\\textasciicircum{}",
  ["\1lt\1"] = "\\textless{}",
  ["\1gt\1"] = "\\textgreater{}",
}

local function escape_text(s)
  if not s or s == "" then
    return ""
  end
  s = s:gsub("[\\&%%%$#_{}~%^<>]", PLACEHOLDERS)
  s = s:gsub("\1[a-z]+\1", PLACEHOLDER_TO_TEX)
  return s
end

-- Pick a \verb delimiter not present in body.  Mirrors the fallback
-- order used by export/latex.lua's inline_to_tex.
local function verb_delim(body)
  if not body:find("|", 1, true) then
    return "|"
  end
  for d in ("!@#~?*"):gmatch(".") do
    if not body:find(d, 1, true) then
      return d
    end
  end
  return "|"
end

-- Per-render link destinations, footnote definitions, and footnotes
-- numbered by first reference (ox-latex emits the body at the first
-- reference and \ref for later ones).
local _index
local _defs = {}
local _fn = { numbers = {}, refs = {}, emitted = {} }

local emit_inline
local emit_block

local function footnote_key(n)
  return n.label or n
end

local function footnote_label(n)
  return "fn:" .. (n.label or _fn.numbers[footnote_key(n)])
end

local function pop_blank(out)
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
end

local function footnote_body(n)
  if n.content then
    return emit_inline(n.content)
  end
  local blocks = _defs[n.label or ""]
  if not blocks then
    return ""
  end
  local sub = {}
  for _, b in ipairs(blocks) do
    emit_block(b, sub)
    pop_blank(sub)
  end
  return (table.concat(sub, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function render_footnote_ref(n)
  local key = footnote_key(n)
  if _fn.emitted[key] then
    return "\\textsuperscript{\\ref{" .. footnote_label(n) .. "}}"
  end
  _fn.emitted[key] = true
  local label = ""
  if (_fn.refs[key] or 0) > 1 then
    label = "\\label{" .. footnote_label(n) .. "}"
  end
  return "\\footnote{" .. footnote_body(n) .. label .. "}"
end

local function render_link(n)
  local desc = (n.description and #n.description > 0) and emit_inline(n.description) or nil
  local r = links.resolve(n.target, _index)
  if r.kind == "headline" then
    return "\\hyperref[sec:" .. r.anchor .. "]{" .. (desc or emit_inline(r.node.title)) .. "}"
  elseif r.kind == "target" then
    if desc then
      return "\\hyperref[" .. r.anchor .. "]{" .. desc .. "}"
    end
    return "\\ref{" .. r.anchor .. "}"
  elseif r.kind == "unresolved" then
    return "\\texttt{" .. (desc or escape_text(n.target)) .. "}"
  end
  local url = r.kind == "file" and (r.path .. (r.fragment and ("#" .. r.fragment) or "")) or r.url
  return "\\href{" .. url .. "}{" .. (desc or escape_text(url)) .. "}"
end

function emit_inline(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  local prev_math_entity = false
  for _, n in ipairs(nodes) do
    local math_entity = false
    if n.kind == "text" then
      out[#out + 1] = escape_text(n.text or "")
    elseif n.kind == "emphasis" then
      local s = n.style
      if s == "verbatim" or s == "code" then
        -- Collect inner as RAW text (verb does its own no-escape).
        local raw = {}
        local function collect(ns)
          for _, c in ipairs(ns or {}) do
            if c.kind == "text" then
              raw[#raw + 1] = c.text or ""
            elseif c.content then
              collect(c.content)
            end
          end
        end
        collect(n.content)
        local body = table.concat(raw)
        local d = verb_delim(body)
        out[#out + 1] = "\\verb" .. d .. body .. d
      else
        local inner = emit_inline(n.content)
        if s == "bold" then
          out[#out + 1] = "\\textbf{" .. inner .. "}"
        elseif s == "italic" then
          out[#out + 1] = "\\textit{" .. inner .. "}"
        elseif s == "underline" then
          out[#out + 1] = "\\underline{" .. inner .. "}"
        elseif s == "strike" then
          out[#out + 1] = "\\sout{" .. inner .. "}"
        else
          out[#out + 1] = inner
        end
      end
    elseif n.kind == "radio_target" then
      out[#out + 1] = escape_text(n.phrase or "")
    elseif n.kind == "link" then
      if n.form == "radio" then
        out[#out + 1] = emit_inline(n.description)
      else
        out[#out + 1] = render_link(n)
      end
    elseif n.kind == "image" then
      out[#out + 1] = "\\includegraphics{" .. (n.target or "") .. "}"
    elseif n.kind == "footnote_ref" then
      out[#out + 1] = render_footnote_ref(n)
    elseif n.kind == "math" then
      if n.display then
        out[#out + 1] = "\\[" .. (n.body or "") .. "\\]"
      else
        out[#out + 1] = "$" .. (n.body or "") .. "$"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "\\\\"
    elseif n.kind == "subscript" then
      out[#out + 1] = "\\textsubscript{" .. emit_inline(n.content) .. "}"
    elseif n.kind == "superscript" then
      out[#out + 1] = "\\textsuperscript{" .. emit_inline(n.content) .. "}"
    elseif n.kind == "entity" then
      local e = ENTITIES[n.name or ""]
      if not e then
        out[#out + 1] = "\\" .. (n.name or "")
      elseif e.math then
        -- Adjacent math entities share one math block (org-latex-math-block).
        if prev_math_entity then
          out[#out] = out[#out]:sub(1, -3) .. e.latex .. "\\)"
        else
          out[#out + 1] = "\\(" .. e.latex .. "\\)"
        end
        math_entity = true
      else
        out[#out + 1] = e.latex
      end
    elseif n.kind == "statistics_cookie" then
      out[#out + 1] = (n.value or ""):gsub("%%", "\\%%")
    elseif n.kind == "timestamp" then
      out[#out + 1] = "\\textit{" .. escape_text(n.value) .. "}"
    elseif n.kind == "target" then
      out[#out + 1] = "\\label{" .. links.target_anchor(n.name) .. "}"
    elseif n.kind == "macro" then
      local args = (n.args and #n.args > 0) and ("(" .. table.concat(n.args, ",") .. ")") or ""
      out[#out + 1] = escape_text("{{{" .. (n.name or "") .. args .. "}}}")
    elseif n.kind == "raw_inline" then
      out[#out + 1] = n.text or ""
    end
    prev_math_entity = math_entity
  end
  local s = table.concat(out)
  local ok, cite = pcall(require, "organ.cite")
  if ok and type(cite.replace_in) == "function" then
    s = cite.replace_in(s, "latex")
  end
  return s
end

local function emit_headline(node, out)
  local level = math.max(1, node.level or 1)
  local cmd = SECTION_CMDS[math.min(level, 5)] or "\\subparagraph"
  out[#out + 1] = cmd .. "{" .. emit_inline(node.title or {}) .. "}"
  out[#out + 1] = "\\label{sec:" .. links.headline_anchor(node) .. "}"
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
  local env = node.ordered and "enumerate" or "itemize"
  out[#out + 1] = "\\begin{" .. env .. "}"
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
      if b.kind == "paragraph" and first then
        out[#out + 1] = "\\item " .. checkbox .. emit_inline(b.inline)
        first = false
      else
        if first then
          out[#out + 1] = ("\\item " .. checkbox):gsub("%s+$", "")
          first = false
        end
        emit_block(b, out)
      end
    end
    if first then
      out[#out + 1] = ("\\item " .. checkbox):gsub("%s+$", "")
    end
    pop_blank(out)
  end
  out[#out + 1] = "\\end{" .. env .. "}"
  out[#out + 1] = ""
end

local function emit_code_block(node, out)
  out[#out + 1] = "\\begin{verbatim}"
  for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = "\\end{verbatim}"
  out[#out + 1] = ""
end

local function emit_org_block(node, out)
  local style = node.style
  if style == "example" then
    emit_code_block({ body = node.body }, out)
  elseif style == "verse" then
    out[#out + 1] = "\\begin{verse}"
    for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = line
    end
    if out[#out] == "" then
      out[#out] = nil
    end
    out[#out + 1] = "\\end{verse}"
    out[#out + 1] = ""
  elseif style == "quote" then
    out[#out + 1] = "\\begin{quotation}"
    for _, b in ipairs(node.content or {}) do
      emit_block(b, out)
    end
    out[#out + 1] = "\\end{quotation}"
    out[#out + 1] = ""
  end
  -- export and unknown styles drop silently.
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

  local align = node.alignments or {}
  local spec_parts = {}
  for c = 1, ncols do
    local a = align[c]
    if a == "c" then
      spec_parts[c] = "c"
    elseif a == "r" then
      spec_parts[c] = "r"
    else
      spec_parts[c] = "l"
    end
  end
  out[#out + 1] = "\\begin{tabular}{" .. table.concat(spec_parts) .. "}"

  for _, r in ipairs(rows) do
    if r.sep then
      out[#out + 1] = "\\hline"
    else
      local cells = {}
      for c = 1, ncols do
        cells[c] = emit_inline(r.cells[c] or {})
      end
      out[#out + 1] = table.concat(cells, " & ") .. " \\\\"
    end
  end

  out[#out + 1] = "\\end{tabular}"
  out[#out + 1] = ""
end

local function emit_image_block(node, out)
  local target = node.target or ""
  out[#out + 1] = "\\begin{figure}[h]"
  out[#out + 1] = "\\centering"
  out[#out + 1] = "\\includegraphics{" .. target .. "}"
  if node.alt and node.alt ~= "" then
    out[#out + 1] = "\\caption{" .. escape_text(node.alt) .. "}"
  end
  out[#out + 1] = "\\end{figure}"
  out[#out + 1] = ""
end

local function emit_rule(_, out)
  out[#out + 1] = "\\hrule"
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
  end
  -- footnote_definition bodies are emitted at their first reference;
  -- directive, drawer, comment intentionally drop.
end

local function find_directive(doc, name)
  if not doc or not doc.children then
    return nil
  end
  for _, c in ipairs(doc.children) do
    if c.kind == "directive" and c.name == name then
      return c.value
    end
  end
  return nil
end

-- Collect footnote definitions and count references per label, so the
-- first reference knows whether to carry a \label.  A description-less
-- link to a headline re-renders that title, so its footnotes count as
-- referenced again.
local function prepare(doc)
  _index = links.index(doc)
  _defs = {}
  _fn = { numbers = {}, refs = {}, emitted = {} }
  local count = 0
  local function count_ref(n)
    local key = footnote_key(n)
    _fn.refs[key] = (_fn.refs[key] or 0) + 1
  end
  A.walk(doc, function(n)
    if n.kind == "footnote_ref" then
      local key = footnote_key(n)
      if not _fn.numbers[key] then
        count = count + 1
        _fn.numbers[key] = count
      end
      count_ref(n)
    elseif n.kind == "footnote_definition" then
      _defs[n.label or ""] = _defs[n.label or ""] or n.content
    elseif
      n.kind == "link"
      and n.form ~= "radio"
      and not (n.description and #n.description > 0)
    then
      local r = links.resolve(n.target, _index)
      if r.kind == "headline" then
        A.walk({ kind = "paragraph", inline = r.node.title }, function(t)
          if t.kind == "footnote_ref" then
            count_ref(t)
          end
        end)
      end
    end
  end)
end

local PREAMBLE = [[\documentclass{article}
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{hyperref}
\usepackage[normalem]{ulem}
\usepackage{amsmath}
\usepackage{amssymb}
\usepackage{graphicx}
]]

function M.render(doc, opts)
  opts = opts or {}
  prepare(doc)

  local body = {}
  for _, c in ipairs(doc.children or {}) do
    emit_block(c, body)
  end

  -- Collapse runs of >1 blank line into one, and trim trailing blanks.
  local collapsed = {}
  local prev_blank = false
  for _, l in ipairs(body) do
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

  if opts.body_only then
    return table.concat(collapsed, "\n") .. "\n"
  end

  local title = find_directive(doc, "TITLE")
  local author = find_directive(doc, "AUTHOR")
  local date = find_directive(doc, "DATE")

  local out = { PREAMBLE }
  if title then
    out[#out + 1] = "\\title{" .. escape_text(title) .. "}"
    if author then
      out[#out + 1] = "\\author{" .. escape_text(author) .. "}"
    end
    if date then
      out[#out + 1] = "\\date{" .. escape_text(date) .. "}"
    end
  end
  out[#out + 1] = "\\begin{document}"
  if title then
    out[#out + 1] = ""
    out[#out + 1] = "\\maketitle"
  end
  out[#out + 1] = ""
  for _, l in ipairs(collapsed) do
    out[#out + 1] = l
  end
  out[#out + 1] = ""
  out[#out + 1] = "\\end{document}"
  return table.concat(out, "\n") .. "\n"
end

-- Expose internals for tests.
M._emit_inline = emit_inline
M._emit_block = emit_block
M._escape_text = escape_text
M._prepare = prepare

return M
