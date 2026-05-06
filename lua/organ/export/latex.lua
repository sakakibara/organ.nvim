-- LaTeX exporter for org buffers. Pure: takes a buffer or source string,
-- returns a string. Mirrors the structure of export/markdown.lua and
-- export/html.lua so they share a mental model.
--
-- The default emit produces a complete `article` document with
-- `hyperref` + `ulem` preamble. Pass opts.body_only = true to emit just
-- the body (handy when embedding into a larger LaTeX project).

local M = {}

local function lstrip(s)
  return s:gsub("^%s+", "")
end

local function heading_level(node, src)
  local sr = node:start()
  local line = src[sr + 1] or ""
  local stars = line:match("^(%*+)%s") or ""
  return #stars
end

local function clean_title(line, todo_keywords)
  line = line:gsub("^%*+%s+", "")
  for _, kw in ipairs(todo_keywords or {}) do
    if kw ~= "|" then
      local pat = "^" .. kw .. "%s+"
      if line:match(pat) then
        line = line:gsub(pat, "")
        break
      end
    end
  end
  line = line:gsub("^%[#%w%]%s*", "")
  line = line:gsub("%s+:[%w_:@]+:%s*$", "")
  return line
end

-- Sectioning commands by org headline level. Beyond paragraph we collapse
-- to subparagraph + noindent — matches Emacs `org-latex-classes` "article"
-- conventions.
local SECTION_CMDS = {
  [1] = "\\section",
  [2] = "\\subsection",
  [3] = "\\subsubsection",
  [4] = "\\paragraph",
  [5] = "\\subparagraph",
}

-- Escape a span of plain text into LaTeX. Excludes characters that are
-- already part of an inline math region (handled separately by inline_to_tex).
--
-- Order matters: replace each special with a unique placeholder, then
-- substitute the LaTeX form at the end. Two-phase keeps later escape passes
-- from re-escaping characters introduced by earlier ones (e.g. the `{` in
-- `\textbackslash{}` would otherwise get caught by the brace escape).
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
  -- Phase 1: every special → placeholder.
  s = s:gsub("[\\&%%%$#_{}~%^<>]", PLACEHOLDERS)
  -- Phase 2: placeholder → LaTeX form.
  s = s:gsub("\1[a-z]+\1", PLACEHOLDER_TO_TEX)
  return s
end

-- Convert one inline org line to LaTeX.
--
-- Strategy: chop the line into math-vs-prose segments. Math segments
-- (`$...$`, `\(...\)`) pass through verbatim; prose segments are escaped
-- and then run through emphasis + link substitution.
local function inline_to_tex(s)
  -- 1) Split into math / prose chunks.
  local chunks = {}
  local i = 1
  while i <= #s do
    local s_dollar = s:find("%$", i)
    local s_paren = s:find("\\%(", i)
    local s_first
    if s_dollar and s_paren then
      s_first = math.min(s_dollar, s_paren)
    else
      s_first = s_dollar or s_paren
    end
    if not s_first then
      chunks[#chunks + 1] = { kind = "prose", text = s:sub(i) }
      break
    end
    if s_first > i then
      chunks[#chunks + 1] = { kind = "prose", text = s:sub(i, s_first - 1) }
    end
    if s:sub(s_first, s_first) == "$" then
      local close = s:find("%$", s_first + 1)
      if close then
        chunks[#chunks + 1] = { kind = "math", text = s:sub(s_first, close) }
        i = close + 1
      else
        chunks[#chunks + 1] = { kind = "prose", text = s:sub(s_first) }
        break
      end
    else -- "\("
      local close = s:find("\\%)", s_first + 2)
      if close then
        chunks[#chunks + 1] = { kind = "math", text = s:sub(s_first, close + 1) }
        i = close + 2
      else
        chunks[#chunks + 1] = { kind = "prose", text = s:sub(s_first) }
        break
      end
    end
  end

  -- 1.5) Stash citations so escape_text doesn't mangle the rendered \cite{}.
  do
    local cite = require("organ.cite")
    for ci, ch in ipairs(chunks) do
      if ch.kind == "prose" then
        local hits = cite.scan(ch.text)
        if #hits > 0 then
          local out, pos = {}, 1
          local stash = {}
          for _, h in ipairs(hits) do
            out[#out + 1] = ch.text:sub(pos, h.s - 1)
            stash[#stash + 1] = cite.render(h.parsed, "latex")
            out[#out + 1] = string.format("\3CITE%d\3", #stash)
            pos = h.e + 1
          end
          out[#out + 1] = ch.text:sub(pos)
          ch.text = table.concat(out)
          ch.cite_stash = stash
        end
      end
    end
  end

  -- 2) Process each prose chunk: extract markup spans into placeholders,
  --    escape the remaining literal text, then substitute the LaTeX forms
  --    back. This prevents escape_text from clobbering `\textbf{...}` etc.
  local out = {}
  for _, ch in ipairs(chunks) do
    if ch.kind == "math" then
      out[#out + 1] = ch.text
    else
      local subs = {}
      local function stash(latex)
        subs[#subs + 1] = latex
        return string.format("\2SPAN%d\2", #subs)
      end
      local p = ch.text
      -- Order matters: links first (their target may contain `*`/`/` etc.).
      p = p:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", function(target, desc)
        return stash(string.format("\\href{%s}{%s}", target, escape_text(desc)))
      end)
      p = p:gsub("%[%[([^%]]-)%]%]", function(target)
        return stash(string.format("\\href{%s}{%s}", target, escape_text(target)))
      end)
      -- Verbatim/code: contents pass through \verb| | unchanged (which is
      -- LaTeX's "no escaping needed" mechanism — but `|` inside breaks it,
      -- so swap to a delimiter not present in the body).
      local function verbify(body)
        local delim = "|"
        if body:find("|", 1, true) then
          for d in ("!@#~?*"):gmatch(".") do
            if not body:find(d, 1, true) then
              delim = d
              break
            end
          end
        end
        return stash("\\verb" .. delim .. body .. delim)
      end
      p = p:gsub("=([^=\n]+)=", function(b)
        return verbify(b)
      end)
      p = p:gsub("~([^~\n]+)~", function(b)
        return verbify(b)
      end)
      p = p:gsub("%*([^%*\n]+)%*", function(b)
        return stash("\\textbf{" .. escape_text(b) .. "}")
      end)
      p = p:gsub("(^[%s%p])/([^/\n]+)/", function(prefix, body)
        return prefix .. stash("\\textit{" .. escape_text(body) .. "}")
      end)
      p = p:gsub("^/([^/\n]+)/", function(b)
        return stash("\\textit{" .. escape_text(b) .. "}")
      end)
      p = p:gsub("_([%w][^_\n]*)_", function(b)
        return stash("\\underline{" .. escape_text(b) .. "}")
      end)
      p = p:gsub("%+([^%+\n]+)%+", function(b)
        return stash("\\sout{" .. escape_text(b) .. "}")
      end)
      -- Now escape what remains of the literal prose.
      p = escape_text(p)
      -- Substitute markup spans back in.
      p = p:gsub("\2SPAN(%d+)\2", function(idx)
        return subs[tonumber(idx)]
      end)
      -- Restore stashed citations (their \cite{} survived escape verbatim).
      if ch.cite_stash then
        p = p:gsub("\3CITE(%d+)\3", function(idx)
          return ch.cite_stash[tonumber(idx)]
        end)
      end
      out[#out + 1] = p
    end
  end
  return table.concat(out)
end

local function emit_headline(node, src, out, opts)
  local level = heading_level(node, src)
  local sr = node:start()
  local title = clean_title(src[sr + 1] or "", opts.todo_keywords)
  local cmd = SECTION_CMDS[math.min(level, 5)] or "\\subparagraph"
  out[#out + 1] = cmd .. "{" .. inline_to_tex(title) .. "}"
  out[#out + 1] = ""
end

local function emit_paragraph(node, src, out)
  local sr, _, er, ec = node:range()
  -- Tree-sitter end position is exclusive: when ec > 0 the paragraph
  -- ends mid-row at column ec (last content row is `er`); when ec == 0
  -- the paragraph ends at the start of row `er` (last content row is
  -- `er - 1`). Without this guard, single-row paragraphs whose source
  -- has no trailing newline (e.g. last line of a document) are dropped.
  local last_row = ec > 0 and er or er - 1
  local lines = {}
  for r = sr, last_row do
    if src[r + 1] then
      lines[#lines + 1] = inline_to_tex(src[r + 1])
    end
  end
  out[#out + 1] = table.concat(lines, "\n")
  out[#out + 1] = ""
end

local function list_kind(child, src)
  -- An ordered list item starts with `1.`, `2.`, `1)`, etc.
  local sr = child:start()
  local raw = src[sr + 1] or ""
  if raw:match("^%s*%d+[.)]") then
    return "enumerate"
  end
  return "itemize"
end

local function emit_list(node, src, out, indent_level)
  indent_level = indent_level or 0
  -- Look at the first list_item to pick environment.
  local first_item
  for c in node:iter_children() do
    if c:type() == "list_item" then
      first_item = c
      break
    end
  end
  local env = first_item and list_kind(first_item, src) or "itemize"
  local pad = string.rep("  ", indent_level)
  out[#out + 1] = pad .. "\\begin{" .. env .. "}"
  for child in node:iter_children() do
    if child:type() == "list_item" then
      local sr = child:start()
      local raw = src[sr + 1] or ""
      local _, _, after = raw:match("^(%s*)([%-%+%*]?%d*[.)]?)%s*(.*)$")
      after = after or ""
      local cbox, body = after:match("^%[([ Xx%-])%]%s*(.*)$")
      if cbox then
        local mark = (cbox == "X" or cbox == "x") and "$\\boxtimes$"
          or (cbox == "-" and "$\\boxminus$" or "$\\square$")
        out[#out + 1] = pad .. "  \\item " .. mark .. " " .. inline_to_tex(body or "")
      else
        out[#out + 1] = pad .. "  \\item " .. inline_to_tex(after)
      end
      for sub in child:iter_children() do
        if sub:type() == "list" then
          emit_list(sub, src, out, indent_level + 1)
        end
      end
    elseif child:type() == "list" then
      emit_list(child, src, out, indent_level + 1)
    end
  end
  out[#out + 1] = pad .. "\\end{" .. env .. "}"
  out[#out + 1] = ""
end

local function emit_src_block(node, src, out)
  local sr, _, er = node:range()
  out[#out + 1] = "\\begin{verbatim}"
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = src[r]
    end
  end
  out[#out + 1] = "\\end{verbatim}"
  out[#out + 1] = ""
end

local function emit_example_block(node, src, out)
  emit_src_block(node, src, out)
end

local function emit_quote_block(node, src, out)
  local sr, _, er = node:range()
  out[#out + 1] = "\\begin{quote}"
  for r = sr + 2, er do
    if src[r] and not src[r]:match("^%s*#%+[Ee][Nn][Dd]_") then
      out[#out + 1] = inline_to_tex(src[r])
    end
  end
  out[#out + 1] = "\\end{quote}"
  out[#out + 1] = ""
end

local function emit_table(node, src, out)
  local sr, _, er = node:range()
  local rows = {} -- { { cells = {...}, divider = bool } }
  for r = sr + 1, er do
    local line = src[r] or ""
    if line:match("^%s*|%-") then
      if rows[#rows] then
        rows[#rows].divider_after = true
      end
    elseif line:match("^%s*|") then
      local cells = {}
      for c in line:gmatch("|([^|]*)") do
        cells[#cells + 1] = lstrip(c):gsub("%s+$", "")
      end
      -- Drop ALL trailing empties (org tables end on `|` so the last
      -- capture is always empty; some grammars also leave an extra one).
      while #cells > 0 and cells[#cells] == "" do
        cells[#cells] = nil
      end
      rows[#rows + 1] = { cells = cells }
    end
  end
  if #rows == 0 then
    return
  end
  local ncols = #rows[1].cells
  local spec = "|" .. string.rep("l|", ncols)
  out[#out + 1] = "\\begin{tabular}{" .. spec .. "}"
  out[#out + 1] = "\\hline"
  for _, r in ipairs(rows) do
    local cells = {}
    for _, c in ipairs(r.cells) do
      cells[#cells + 1] = inline_to_tex(c)
    end
    out[#out + 1] = table.concat(cells, " & ") .. " \\\\"
    if r.divider_after then
      out[#out + 1] = "\\hline"
    end
  end
  out[#out + 1] = "\\hline"
  out[#out + 1] = "\\end{tabular}"
  out[#out + 1] = ""
end

local function emit_horizontal_rule(_, _, out)
  out[#out + 1] = "\\noindent\\rule{\\linewidth}{0.4pt}"
  out[#out + 1] = ""
end

local DROP_TYPES = {
  drawer = true,
  property_drawer = true,
  planning = true,
  clock = true,
  comment = true,
  comment_block = true,
  affiliated_keyword = true,
  keyword = true,
  diary_sexp = true,
}

local function walk(node, src, out, opts)
  local t = node:type()
  if DROP_TYPES[t] then
    return
  end
  if t == "headline" then
    emit_headline(node, src, out, opts)
    for c in node:iter_children() do
      if c:named() then
        walk(c, src, out, opts)
      end
    end
  elseif t == "section" or t == "zeroth_section" or t == "document" then
    for c in node:iter_children() do
      if c:named() then
        walk(c, src, out, opts)
      end
    end
  elseif t == "paragraph" then
    emit_paragraph(node, src, out)
  elseif t == "list" then
    emit_list(node, src, out, 0)
  elseif t == "src_block" then
    emit_src_block(node, src, out)
  elseif t == "example_block" or t == "verse_block" then
    emit_example_block(node, src, out)
  elseif t == "quote_block" then
    emit_quote_block(node, src, out)
  elseif t == "horizontal_rule" then
    emit_horizontal_rule(node, src, out)
  elseif t == "table" then
    emit_table(node, src, out)
  elseif t == "footnote_definition" then
    emit_paragraph(node, src, out)
  end
end

-- Pick up #+TITLE, #+AUTHOR, #+DATE in the file's pre-headline area.
local function scan_keywords(lines)
  local kw = {}
  for _, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      break
    end
    local k, v = ln:match("^%s*#%+(%u+):%s*(.+)%s*$")
    if k and v then
      kw[k] = v
    end
  end
  return kw
end

local PREAMBLE = [[\documentclass{article}
\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{hyperref}
\usepackage{ulem}
\usepackage{amsmath}
\usepackage{amssymb}
\usepackage{graphicx}
]]

function M.export(src, opts)
  opts = opts or {}
  local lines
  if type(src) == "string" then
    lines = vim.split(src, "\n", { plain = true })
  else
    lines = src
  end
  local text = table.concat(lines, "\n")

  if opts.expand then
    text = require("organ.expand").process(text, {
      base_dir = opts.base_dir,
      file_path = opts.file_path,
      properties = opts.properties,
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local native_ctx
  if opts.cite_native then
    text, native_ctx = require("organ.cite").preprocess_native(text, {
      style = opts.cite_style,
      bib_files = opts.bib_files,
      backend = "latex",
    })
    lines = vim.split(text, "\n", { plain = true })
  end

  local parser = vim.treesitter.get_string_parser(text, "org")
  local root = parser:parse()[1]:root()

  opts.todo_keywords = opts.todo_keywords
    or (require("organ").config.todo and require("organ").config.todo.sequence)
    or { "TODO", "|", "DONE" }

  local kw = scan_keywords(lines)
  local body = {}
  walk(root, lines, body, opts)

  -- Collapse runs of >2 blank lines into 1.
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

  local function finish(s)
    if native_ctx then
      s = require("organ.cite").finalize_native(s, native_ctx)
    end
    return s
  end

  if opts.body_only then
    return finish(table.concat(collapsed, "\n") .. "\n")
  end

  local out = { PREAMBLE }
  if kw.TITLE then
    out[#out + 1] = "\\title{" .. inline_to_tex(kw.TITLE) .. "}"
  end
  if kw.AUTHOR then
    out[#out + 1] = "\\author{" .. inline_to_tex(kw.AUTHOR) .. "}"
  end
  if kw.DATE then
    out[#out + 1] = "\\date{" .. inline_to_tex(kw.DATE) .. "}"
  end
  out[#out + 1] = "\\begin{document}"
  if kw.TITLE then
    out[#out + 1] = "\\maketitle"
  end
  out[#out + 1] = ""
  for _, l in ipairs(collapsed) do
    out[#out + 1] = l
  end
  out[#out + 1] = "\\end{document}"
  return finish(table.concat(out, "\n") .. "\n")
end

function M.export_buffer(bufnr, opts)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.export(lines, opts)
end

function M.export_buffer_to_file(bufnr, path, opts)
  bufnr = bufnr or 0
  if not path or path == "" then
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return nil, "no buffer name; specify a path"
    end
    path = name:gsub("%.org$", "") .. ".tex"
  end
  local out = M.export_buffer(bufnr, opts)
  local ok, werr = require("organ.path").write_atomic(path, out)
  if not ok then
    return nil, "could not write " .. path .. ": " .. tostring(werr)
  end
  return path
end

-- Exposed for tests + beamer backend.
M._inline_to_tex = inline_to_tex
M._escape_text = escape_text
M._scan_keywords = scan_keywords
M._walk = walk
M._emit_headline = emit_headline

return M
