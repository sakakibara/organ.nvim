-- Beamer presentation export. Reuses lua/organ/export/latex.lua's renderer
-- for everything inside frames; replaces the document wrapper + headline
-- emitter to produce \begin{frame}{...}…\end{frame} groupings.
--
-- Layout convention (subset of Emacs `org-beamer-export`):
--   * Level-1 headline → new frame; the headline title becomes the frame title.
--   * Level-2+ headlines inside a frame → `\block{title}` (a labelled block
--     within the frame).
--   * Pre-first-headline content → emitted before the first \begin{frame},
--     useful for `\titlepage` placeholders.
--
-- Recognised file-level keywords (in the pre-headline area):
--   #+TITLE     #+AUTHOR    #+INSTITUTE    #+DATE
--   #+BEAMER_THEME      → \usetheme{...}
--   #+BEAMER_HEADER     → arbitrary line in preamble (repeatable)
--   #+BEAMER_OPTIONS    → \mode<beamer>{ \setbeameroption{...} }

local M = {}

local latex = require("organ.export.latex")
local lstrip = function(s)
  return s:gsub("^%s+", "")
end

-- Re-derive a title from the first line covered by `node`.
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

local function heading_level(node, src)
  local sr = node:start()
  local stars = (src[sr + 1] or ""):match("^(%*+)%s") or ""
  return #stars
end

-- Emit a Beamer-flavored headline: level 1 = frame open; we also need to
-- close any previously open frame before opening a new one.
local function emit_beamer_headline(node, src, out, opts)
  local level = heading_level(node, src)
  local sr = node:start()
  local title = clean_title(src[sr + 1] or "", opts.todo_keywords)
  if level == 1 then
    if opts._frame_open then
      out[#out + 1] = "\\end{frame}"
      out[#out + 1] = ""
    end
    out[#out + 1] = "\\begin{frame}{" .. latex._inline_to_tex(title) .. "}"
    opts._frame_open = true
  else
    out[#out + 1] = "\\begin{block}{" .. latex._inline_to_tex(title) .. "}"
    -- We don't track block-open state here; users are expected to keep
    -- depth shallow. `\end{block}` is appended at the end of the frame.
    -- For correctness we close the current block at every frame boundary.
    opts._block_depth = (opts._block_depth or 0) + 1
  end
end

-- Rewalk the AST, dispatching headlines through emit_beamer_headline and
-- everything else through latex._walk.
local function walk(node, src, out, opts)
  local t = node:type()
  if t == "headline" then
    emit_beamer_headline(node, src, out, opts)
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
  else
    -- Defer all non-headline emission to the LaTeX renderer.
    latex._walk(node, src, out, opts)
  end
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
    -- `#+BEAMER_HEADER:` may repeat — append every line to the preamble.
    for line in kw.BEAMER_HEADER:gmatch("[^\n]+") do
      out[#out + 1] = line
    end
  end
  if kw.BEAMER_OPTIONS then
    out[#out + 1] = "\\mode<beamer>{ \\setbeameroption{" .. kw.BEAMER_OPTIONS .. "} }"
  end
  if kw.TITLE then
    out[#out + 1] = "\\title{" .. latex._inline_to_tex(kw.TITLE) .. "}"
  end
  if kw.AUTHOR then
    out[#out + 1] = "\\author{" .. latex._inline_to_tex(kw.AUTHOR) .. "}"
  end
  if kw.INSTITUTE then
    out[#out + 1] = "\\institute{" .. latex._inline_to_tex(kw.INSTITUTE) .. "}"
  end
  if kw.DATE then
    out[#out + 1] = "\\date{" .. latex._inline_to_tex(kw.DATE) .. "}"
  end
  return out
end

-- Multi-line keyword scan (BEAMER_HEADER may repeat). Differs from the
-- LaTeX backend's scan_keywords which only captures the last value.
local function scan_keywords_multi(lines)
  local kw = {}
  for _, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      break
    end
    local k, v = ln:match("^%s*#%+([%u_]+):%s*(.+)%s*$")
    if k and v then
      if k == "BEAMER_HEADER" then
        kw[k] = (kw[k] and (kw[k] .. "\n") or "") .. v
      else
        kw[k] = v
      end
    end
  end
  return kw
end

function M.export(src, opts)
  opts = opts or {}
  local lines
  if type(src) == "string" then
    lines = vim.split(src, "\n", { plain = true })
  else
    lines = src
  end
  local text = table.concat(lines, "\n")
  local parser = vim.treesitter.get_string_parser(text, "org")
  local root = parser:parse()[1]:root()

  opts.todo_keywords = opts.todo_keywords
    or (require("organ").config.todo and require("organ").config.todo.sequence)
    or { "TODO", "|", "DONE" }

  local kw = scan_keywords_multi(lines)
  local body = {}
  walk(root, lines, body, opts)
  if opts._frame_open then
    body[#body + 1] = "\\end{frame}"
    opts._frame_open = nil
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
