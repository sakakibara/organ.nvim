-- Beamer presentation export. Reuses the AST-driven LaTeX renderer for
-- everything inside frames; replaces the document wrapper + headline
-- emitter to produce \begin{frame}{...}...\end{frame} groupings.
--
-- Layout convention (subset of Emacs `org-beamer-export`):
--   * Level-1 headline -> new frame; the headline title becomes the frame title.
--   * Level-2+ headlines inside a frame -> `\block{title}` (a labelled block
--     within the frame).
--   * Pre-first-headline content -> emitted before the first \begin{frame},
--     useful for `\titlepage` placeholders.
--
-- Recognised file-level keywords (in the pre-headline area):
--   #+TITLE     #+AUTHOR    #+INSTITUTE    #+DATE
--   #+BEAMER_THEME      -> \usetheme{...}
--   #+BEAMER_HEADER     -> arbitrary line in preamble (repeatable)
--   #+BEAMER_OPTIONS    -> \mode<beamer>{ \setbeameroption{...} }

local M = {}

local to_latex = require("organ.ast.to_latex")

-- Render the descendants of a headline (children of children, etc.):
-- nested headlines become `\begin{block}{title}` and their own children
-- recurse; everything else delegates to the LaTeX block renderer.
local function emit_frame_children(headline, out)
  for _, c in ipairs(headline.children or {}) do
    if c.kind == "headline" then
      out[#out + 1] = "\\begin{block}{" .. to_latex._emit_inline(c.title or {}) .. "}"
      emit_frame_children(c, out)
      out[#out + 1] = "\\end{block}"
      out[#out + 1] = ""
    else
      to_latex._emit_block(c, out)
    end
  end
end

-- Collect #+KEYWORDs from the document's top-level directive nodes.
-- BEAMER_HEADER may repeat; concatenate its values with newlines.
local function collect_keywords(doc)
  local kw = {}
  for _, c in ipairs(doc.children or {}) do
    if c.kind == "directive" then
      local k, v = c.name, c.value
      if k == "BEAMER_HEADER" then
        kw[k] = (kw[k] and (kw[k] .. "\n") or "") .. v
      else
        kw[k] = v
      end
    end
  end
  return kw
end

local function build_preamble(kw)
  local out = {
    "\\documentclass[presentation]{beamer}",
    "\\usepackage[utf8]{inputenc}",
    "\\usepackage[T1]{fontenc}",
    "\\usepackage{hyperref}",
    "\\usepackage{ulem}",
    "\\usepackage{amsmath}",
    "\\usepackage{amssymb}",
    "\\usepackage{graphicx}",
  }
  if kw.BEAMER_THEME then
    out[#out + 1] = "\\usetheme{" .. kw.BEAMER_THEME .. "}"
  end
  if kw.BEAMER_HEADER then
    for line in kw.BEAMER_HEADER:gmatch("[^\n]+") do
      out[#out + 1] = line
    end
  end
  if kw.BEAMER_OPTIONS then
    out[#out + 1] = "\\mode<beamer>{ \\setbeameroption{" .. kw.BEAMER_OPTIONS .. "} }"
  end
  if kw.TITLE then
    out[#out + 1] = "\\title{" .. to_latex._escape_text(kw.TITLE) .. "}"
  end
  if kw.AUTHOR then
    out[#out + 1] = "\\author{" .. to_latex._escape_text(kw.AUTHOR) .. "}"
  end
  if kw.INSTITUTE then
    out[#out + 1] = "\\institute{" .. to_latex._escape_text(kw.INSTITUTE) .. "}"
  end
  if kw.DATE then
    out[#out + 1] = "\\date{" .. to_latex._escape_text(kw.DATE) .. "}"
  end
  return out
end

function M.export(src, opts)
  opts = opts or {}
  local lines
  if type(src) == "string" then
    lines = vim.split(src, "\n", { plain = true })
  else
    lines = src
  end

  local ast = require("organ.ast.from_org").from_lines(lines)
  local ok, err = require("organ.ast").validate(ast)
  if not ok then
    error("export.beamer: AST validation failed: " .. err)
  end
  ast = require("organ.ast.radio").resolve(ast)
  to_latex._prepare(ast)

  local kw = collect_keywords(ast)

  -- Emit the body: each level-1 headline opens a frame; non-headline
  -- top-level blocks emit before any frames open.
  local body = {}
  local frame_open = false
  for _, c in ipairs(ast.children or {}) do
    if c.kind == "headline" and (c.level or 1) == 1 then
      if frame_open then
        body[#body + 1] = "\\end{frame}"
        body[#body + 1] = ""
      end
      body[#body + 1] = "\\begin{frame}{" .. to_latex._emit_inline(c.title or {}) .. "}"
      frame_open = true
      emit_frame_children(c, body)
    elseif c.kind == "directive" then
      -- Already captured into kw.
    else
      to_latex._emit_block(c, body)
    end
  end
  if frame_open then
    body[#body + 1] = "\\end{frame}"
  end

  -- Collapse blank-line runs.
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

  local doc = {}
  for _, l in ipairs(build_preamble(kw)) do
    doc[#doc + 1] = l
  end
  doc[#doc + 1] = "\\begin{document}"
  if kw.TITLE then
    doc[#doc + 1] = "\\frame{\\titlepage}"
  end
  doc[#doc + 1] = ""
  for _, l in ipairs(collapsed) do
    doc[#doc + 1] = l
  end
  doc[#doc + 1] = "\\end{document}"
  return table.concat(doc, "\n") .. "\n"
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

return M
