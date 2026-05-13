-- Document AST -> LaTeX string.
--
-- Companion to from_org.lua.  Emits a complete `article` document
-- (preamble + \begin{document} ... \end{document}) wrapping a body
-- rendered from the AST.  Inline math regions pass through verbatim;
-- the body of \verb spans skips the special-char escape table since
-- \verb provides its own no-escape semantics.

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

-- Set whenever a math region is encountered.  Reserved for future use
-- (e.g. preamble decisions); currently unused but reset per-render so
-- a stale value from a previous render can never leak in.
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
    elseif n.kind == "link" then
      local target = n.target or ""
      if n.description and #n.description > 0 then
        out[#out + 1] = "\\href{" .. target .. "}{" .. emit_inline(n.description) .. "}"
      else
        out[#out + 1] = "\\href{" .. target .. "}{" .. escape_text(target) .. "}"
      end
    elseif n.kind == "image" then
      out[#out + 1] = "\\includegraphics{" .. (n.target or "") .. "}"
    elseif n.kind == "footnote_ref" then
      out[#out + 1] = "\\footnotemark[" .. (n.label or "") .. "]"
    elseif n.kind == "math" then
      _math_used = true
      if n.display then
        out[#out + 1] = "\\[" .. (n.body or "") .. "\\]"
      else
        out[#out + 1] = "$" .. (n.body or "") .. "$"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "\\\\"
    end
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
      if b.kind == "paragraph" then
        if first then
          out[#out + 1] = "\\item " .. checkbox .. emit_inline(b.inline)
          first = false
        else
          out[#out + 1] = emit_inline(b.inline)
        end
      elseif b.kind == "list" then
        emit_list(b, out)
      end
    end
    if first and checkbox ~= "" then
      out[#out + 1] = "\\item " .. checkbox
    elseif first then
      out[#out + 1] = "\\item"
    end
  end
  out[#out + 1] = "\\end{" .. env .. "}"
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
  end
  -- All other kinds added in subsequent tasks.
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

local PREAMBLE = [[\documentclass{article}
\usepackage[utf8]{inputenc}
\usepackage{hyperref}
\usepackage{graphicx}
\usepackage[normalem]{ulem}
]]

function M.render(doc, opts)
  opts = opts or {}
  _math_used = false

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
M._PREAMBLE = PREAMBLE

return M
