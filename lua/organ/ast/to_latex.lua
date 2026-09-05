-- Document AST -> LaTeX string.
--
-- Companion to from_org.lua.  Emits a complete `article` document
-- (preamble + \begin{document} ... \end{document}) wrapping a body
-- rendered from the AST.  Inline math regions pass through verbatim;
-- verbatim spans become \texttt{} with their specials protected, which
-- unlike \verb survives a moving argument such as \section{}.

local A = require("organ.ast")
local links = require("organ.ast.links")
local ENTITIES = require("organ.ast.org_entities")
local OPTIONS = require("organ.export.options")

local M = {}

-- Resolved export options and the caption sequence numbers.
local _o = OPTIONS.defaults()
local _ordinal = {}
-- Set when a `#+TOC: headlines N local` needs the titletoc package.
local _titletoc = false
-- Headline a `#+TOC: ... local` sits under, while its section emits.
local _toc_scope

local function affiliated(node, name)
  for _, a in ipairs(node.affiliated or {}) do
    if a.name == name then
      return a
    end
  end
end

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

-- Plain text carries the export options TeX itself cannot express:
-- `...` needs \ldots, quotes need the TeX quoting pairs, and a
-- preserved line break needs an explicit `\\`.  `--` and `---` are
-- left alone -- TeX ligatures already render them.
local function plain_text(s)
  s = escape_text(s)
  if _o.with_special_strings then
    s = s:gsub("%.%.%.", "\\ldots{}")
  end
  if _o.with_smart_quotes then
    s = s:gsub('()"', function(pos)
      local prev = s:sub(pos - 1, pos - 1)
      return (prev == "" or prev:match("[%s%(%[{]")) and "``" or "''"
    end)
  end
  if _o.preserve_breaks then
    s = s:gsub("\n", "\\\\\n")
  end
  return s
end

-- org-latex--protect-text: the escape used for a URL, which must not
-- go through escape_text (that would turn `%` into a comment start
-- only after `\` had already been doubled).
local function protect_text(s)
  return (tostring(s or ""):gsub("[\\{}%$%%&_#~%^]", "\\%0"))
end

-- org-latex--protect-texttt: verbatim spans become \texttt{}, which
-- has neither \verb's exhaustible delimiter set nor its fragility in a
-- moving argument.
local TEXTTT = {
  ["--"] = "-{}-{}",
  ["<<"] = "<{}<{}",
  [">>"] = ">{}>{}",
  ["\\"] = "\\textbackslash{}",
  ["~"] = "\\textasciitilde{}",
  ["^"] = "\\textasciicircum{}",
}

local TEXTTT_PAIR = { a = "-{}-{}", b = "<{}<{}", c = ">{}>{}" }

local function protect_texttt(s)
  s = tostring(s or "")
  s = s:gsub("%-%-", "\1a\1"):gsub("<<", "\1b\1"):gsub(">>", "\1c\1")
  s = s:gsub("[\\{}%$%%&_#~%^]", function(ch)
    return TEXTTT[ch] or ("\\" .. ch)
  end)
  return (s:gsub("\1(%a)\1", TEXTTT_PAIR))
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
  if desc then
    return "\\href{" .. protect_text(url) .. "}{" .. desc .. "}"
  end
  return "\\url{" .. protect_text(url) .. "}"
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
      out[#out + 1] = plain_text(n.text or "")
    elseif n.kind == "emphasis" then
      local s = n.style
      if s == "verbatim" or s == "code" then
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
        out[#out + 1] = "\\texttt{" .. protect_texttt(table.concat(raw)) .. "}"
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
      if n.alt and n.alt ~= "" then
        -- A described link is a hyperlink, never an inline image.
        out[#out + 1] = "\\href{" .. protect_text(n.target) .. "}{" .. escape_text(n.alt) .. "}"
      else
        out[#out + 1] = "\\includegraphics{" .. (n.target or "") .. "}"
      end
    elseif n.kind == "footnote_ref" then
      out[#out + 1] = render_footnote_ref(n)
    elseif n.kind == "math" then
      -- `$$...$$` is only rewritten to `\[...\]` by ox-html; LaTeX keeps
      -- the delimiters the source used.
      if n.display then
        if n.style == "dollar" then
          out[#out + 1] = "$$" .. (n.body or "") .. "$$"
        else
          out[#out + 1] = "\\[" .. (n.body or "") .. "\\]"
        end
      else
        out[#out + 1] = "\\(" .. (n.body or "") .. "\\)"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "\\\\"
    elseif n.kind == "subscript" then
      out[#out + 1] = "\\textsubscript{" .. emit_inline(n.content) .. "}"
    elseif n.kind == "superscript" then
      out[#out + 1] = "\\textsuperscript{" .. emit_inline(n.content) .. "}"
    elseif n.kind == "entity" then
      -- `\alpha{}` names the same entity as `\alpha`; the braces only
      -- terminate the name.
      local ename = (n.name or ""):gsub("{}$", "")
      local e = ENTITIES[ename]
      if not e then
        out[#out + 1] = "\\" .. ename
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

-- org-latex-headline: TODO keyword, priority cookie and tags each get
-- their own markup around the title.
local function headline_title(node)
  local parts = {}
  if _o.with_todo_keywords and node.todo and node.todo ~= "" then
    parts[#parts + 1] = "{\\bfseries\\sffamily " .. escape_text(node.todo) .. "} "
  end
  if _o.with_priority and node.priority and node.priority ~= "" then
    parts[#parts + 1] = "\\framebox{\\#" .. escape_text(node.priority) .. "} "
  end
  parts[#parts + 1] = emit_inline(node.title or {})
  if _o.with_tags and node.tags and #node.tags > 0 then
    parts[#parts + 1] = "\\hfill{}\\textsc{" .. escape_text(table.concat(node.tags, ":")) .. "}"
  end
  return table.concat(parts)
end

local function emit_planning(node, out)
  local p = node.planning
  if not (_o.with_planning and p) then
    return
  end
  local parts = {}
  for _, k in ipairs({ "closed", "deadline", "scheduled" }) do
    if p[k] then
      parts[#parts + 1] = "\\textbf{" .. k:upper() .. ":} \\textit{" .. escape_text(p[k]) .. "}"
    end
  end
  if #parts > 0 then
    out[#out + 1] = "\\noindent" .. table.concat(parts, " ") .. "\\\\"
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
      lines[#lines + 1] = k .. ": " .. node.properties[k]
    end
  end
  if #lines > 0 then
    out[#out + 1] = "\\begin{verbatim}"
    for _, l in ipairs(lines) do
      out[#out + 1] = l
    end
    out[#out + 1] = "\\end{verbatim}"
  end
end

-- org-latex-keyword: `#+TOC: headlines N [local]`, `tables`, `listings`.
-- `figures` is accepted and, as in ox-latex, renders nothing.  A local
-- TOC is titletoc's \startcontents / \printcontents pair, closed by
-- emit_headline; Emacs assumes the same package.
local function toc_local_level(value, scope)
  local v = value:lower()
  if v:find("headlines") and v:find("local") and scope then
    return scope.level or 1
  end
  return nil
end

local function emit_toc_keyword(value, out, scope)
  local v = value:lower()
  if v:find("headlines") then
    local n = tonumber(v:match("%f[%d]%d+%f[%D]"))
    local level = toc_local_level(value, scope)
    local depth = n and ("\\setcounter{tocdepth}{" .. (n + (level or 0)) .. "}") or nil
    if level then
      _titletoc = true
      out[#out + 1] = "\\startcontents[level-" .. level .. "]"
      out[#out + 1] = "\\printcontents[level-" .. level .. "]{}{0}{" .. (depth or "") .. "}"
    else
      if depth then
        out[#out + 1] = depth
      end
      out[#out + 1] = "\\tableofcontents"
    end
    out[#out + 1] = ""
  elseif v:find("tables") then
    out[#out + 1] = "\\listoftables"
    out[#out + 1] = ""
  elseif v:find("listings") then
    out[#out + 1] = "\\lstlistoflistings"
    out[#out + 1] = ""
  end
end

-- ox.el `org-export-low-level-p`: `#+OPTIONS: H:N` renders a headline
-- deeper than N as a list item rather than as a sectioning command.
local function low_level(n)
  return n.kind == "headline"
    and type(_o.headline_levels) == "number"
    and (n.level or 1) > _o.headline_levels
end

-- ox.el `org-export-numbered-headline-p`: `num:N` numbers only the first
-- N levels, so a deeper headline demotes to an itemize.
local function numbered(n)
  local sec = _o.with_section_numbers
  if type(sec) == "number" then
    return (n.level or 1) <= sec
  end
  return not not sec
end

local emit_children

local function emit_low_level(nodes, out)
  local env = numbered(nodes[1]) and "enumerate" or "itemize"
  out[#out + 1] = "\\begin{" .. env .. "}"
  for _, n in ipairs(nodes) do
    out[#out + 1] = "\\item " .. headline_title(n)
    out[#out + 1] = "\\label{sec:" .. links.headline_anchor(n) .. "}"
    out[#out + 1] = ""
    emit_planning(n, out)
    emit_properties(n, out)
    emit_children(n.children or {}, out)
  end
  out[#out + 1] = "\\end{" .. env .. "}"
  out[#out + 1] = ""
end

-- Walk a block list, gathering each run of demoted headline siblings into
-- a single list environment.
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
  local level = math.max(1, node.level or 1)
  local cmd = SECTION_CMDS[math.min(level, 5)] or "\\subparagraph"
  local star = _o.with_section_numbers and "" or "*"
  out[#out + 1] = cmd .. star .. "{" .. headline_title(node) .. "}"
  out[#out + 1] = "\\label{sec:" .. links.headline_anchor(node) .. "}"
  out[#out + 1] = ""
  emit_planning(node, out)
  emit_properties(node, out)
  local outer = _toc_scope
  _toc_scope = node
  emit_children(node.children or {}, out)
  _toc_scope = outer
  for _, c in ipairs(node.children or {}) do
    if c.kind == "directive" and (c.name or ""):upper() == "TOC" then
      local lvl = toc_local_level(c.value or "", node)
      if lvl then
        out[#out + 1] = "\\stopcontents[level-" .. lvl .. "]"
        out[#out + 1] = ""
        break
      end
    end
  end
end

local function emit_paragraph(node, out)
  out[#out + 1] = emit_inline(node.inline or {})
  out[#out + 1] = ""
end

local function emit_list(node, out)
  local items = node.items or {}
  local described = items[1] and items[1].tag ~= nil
  local env = described and "description" or (node.ordered and "enumerate" or "itemize")
  out[#out + 1] = "\\begin{" .. env .. "}"
  for _, item in ipairs(items) do
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = "[ ] "
    elseif item.checkbox == "done" then
      checkbox = "[X] "
    elseif item.checkbox == "part" then
      checkbox = "[-] "
    end
    -- `- term :: definition` is LaTeX's \item[{term}].
    local marker = "\\item "
    if described then
      marker = "\\item[{" .. emit_inline(item.tag or {}) .. "}] "
    end
    local first = true
    for _, b in ipairs(item.content or {}) do
      if b.kind == "paragraph" and first then
        out[#out + 1] = marker .. checkbox .. emit_inline(b.inline)
        first = false
      else
        if first then
          out[#out + 1] = (marker .. checkbox):gsub("%s+$", "")
          first = false
        end
        emit_block(b, out)
      end
    end
    if first then
      out[#out + 1] = (marker .. checkbox):gsub("%s+$", "")
    end
    pop_blank(out)
  end
  out[#out + 1] = "\\end{" .. env .. "}"
  out[#out + 1] = ""
end

local function ordinal(kind)
  _ordinal[kind] = (_ordinal[kind] or 0) + 1
  return _ordinal[kind]
end

-- `\caption{\label{<prefix>:<name>}<caption>}`, or nil when the block
-- carries no `#+CAPTION:`.
local function caption_line(node, prefix)
  local a = affiliated(node, "CAPTION")
  if not a then
    return nil
  end
  local name = affiliated(node, "NAME")
  local label = "\\label{"
    .. prefix
    .. ":"
    .. (name and name.value or (prefix .. ordinal(prefix)))
    .. "}"
  return label .. (a.inline and emit_inline(a.inline) or escape_text(a.value))
end

local function emit_verbatim(body, out)
  out[#out + 1] = "\\begin{verbatim}"
  for line in ((body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = "\\end{verbatim}"
  out[#out + 1] = ""
end

local function emit_code_block(node, out)
  emit_verbatim(node.body, out)
  local cap = caption_line(node, "lst")
  if cap then
    out[#out] = "\\captionof{figure}{" .. cap .. "}"
    out[#out + 1] = ""
  end
end

local function emit_fixed_width(node, out)
  emit_verbatim(node.body, out)
end

local function emit_latex_environment(node, out)
  if not _o.with_latex then
    return
  end
  if _o.with_latex == "verbatim" then
    out[#out + 1] = escape_text(node.body or "")
  else
    for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = line
    end
    if out[#out] == "" then
      out[#out] = nil
    end
  end
  out[#out + 1] = ""
end

local function emit_org_block(node, out)
  local style = node.style
  if style == "example" then
    emit_verbatim(node.body, out)
  elseif style == "verse" then
    out[#out + 1] = "\\begin{verse}"
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
        local lead, rest = line:match("^( *)(.*)$")
        local indent = #lead > 0 and ("\\hspace*{" .. #lead .. "\\fontdimen2\\font}") or ""
        out[#out + 1] = indent .. rest .. "\\\\"
      end
      if out[#out] == "\\\\" then
        out[#out] = nil
      end
    else
      for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
      if out[#out] == "" then
        out[#out] = nil
      end
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
  elseif style == "export" then
    if (node.backend or ""):lower() == "latex" then
      for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
      end
      if out[#out] == "" then
        out[#out] = nil
      end
      out[#out + 1] = ""
    end
  elseif node.content then
    -- Every other greater block, `center` included, becomes the LaTeX
    -- environment of the same name (org-latex-special-block).
    out[#out + 1] = "\\begin{" .. (style or "") .. "}"
    for _, b in ipairs(node.content) do
      emit_block(b, out)
    end
    pop_blank(out)
    out[#out + 1] = "\\end{" .. (style or "") .. "}"
    out[#out + 1] = ""
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

  local align = table_alignments(node)
  local spec_parts = {}
  for c = 1, ncols do
    spec_parts[c] = align[c] or "l"
  end
  local cap = caption_line(node, "tab")
  if cap then
    out[#out + 1] = "\\begin{table}[htbp]"
    out[#out + 1] = "\\caption{" .. cap .. "}"
    out[#out + 1] = "\\centering"
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
  if cap then
    out[#out + 1] = "\\end{table}"
  end
  out[#out + 1] = ""
end

local function emit_image_block(node, out)
  local target = node.target or ""
  if node.alt and node.alt ~= "" then
    out[#out + 1] = "\\href{" .. protect_text(target) .. "}{" .. escape_text(node.alt) .. "}"
    out[#out + 1] = ""
    return
  end
  out[#out + 1] = "\\begin{figure}[htbp]"
  out[#out + 1] = "\\centering"
  out[#out + 1] = "\\includegraphics{" .. target .. "}"
  local cap = caption_line(node, "fig")
  if cap then
    out[#out + 1] = "\\caption{" .. cap .. "}"
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
  elseif kind == "fixed_width" then
    emit_fixed_width(node, out)
  elseif kind == "latex_environment" then
    emit_latex_environment(node, out)
  elseif kind == "directive" and (node.name or ""):upper() == "TOC" then
    emit_toc_keyword(node.value or "", out, _toc_scope)
  end
  -- footnote_definition bodies are emitted at their first reference;
  -- other directives, drawer, comment intentionally drop.
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
  _titletoc = false
  _toc_scope = nil
  _index = links.index(doc)
  _defs = {}
  _fn = { numbers = {}, refs = {}, emitted = {} }
  _o = (doc and doc.options) or OPTIONS.defaults()
  _ordinal = {}
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
  emit_children(doc.children or {}, body)

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

  local title = _o.with_title and (_o.title or find_directive(doc, "TITLE")) or nil
  local author = _o.with_author and (_o.author or find_directive(doc, "AUTHOR")) or nil
  local date = _o.with_date and (_o.date or find_directive(doc, "DATE")) or nil

  local out = { PREAMBLE }
  if _titletoc then
    out[#out + 1] = "\\usepackage{titletoc}"
  end
  if title then
    out[#out + 1] = "\\title{" .. escape_text(title) .. "}"
    if author then
      local who = escape_text(author)
      if _o.with_email and _o.email and _o.email ~= "" then
        who = who .. "\\thanks{" .. escape_text(_o.email) .. "}"
      end
      out[#out + 1] = "\\author{" .. who .. "}"
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
  if _o.with_toc then
    out[#out + 1] = ""
    out[#out + 1] = "\\tableofcontents"
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
