-- ASCII / plain-text renderer for organ.nvim AST.
--
-- Produces a faithful but bare rendition: headlines underlined with
-- `= - ~ . _`, emphasis markers stripped (content preserved), links
-- shown as `text (url)`, inline images/footnote_refs dropped, math
-- rendered as raw body text.

local M = {}

local emit_inline
local emit_block

local UNDERLINES = { "=", "-", "~", ".", "_" }

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
    elseif n.kind == "link" then
      local target = n.target or ""
      if n.description and #n.description > 0 then
        out[#out + 1] = emit_inline(n.description) .. " (" .. target .. ")"
      else
        out[#out + 1] = target
      end
    elseif n.kind == "math" then
      out[#out + 1] = n.body or ""
    elseif n.kind == "linebreak" then
      out[#out + 1] = "\n"
    end
    -- image / footnote_ref intentionally drop (no ascii syntax)
  end
  local s = table.concat(out)
  local ok, cite = pcall(require, "organ.cite")
  if ok and type(cite.replace_in) == "function" then
    s = cite.replace_in(s, "ascii")
  end
  return s
end

local function emit_headline(node, out)
  local title_text = emit_inline(node.title)
  out[#out + 1] = title_text
  local level = node.level or 1
  if level >= 1 and level <= #UNDERLINES then
    out[#out + 1] = string.rep(UNDERLINES[level], math.max(1, vim.fn.strdisplaywidth(title_text)))
  end
  out[#out + 1] = ""
  for _, c in ipairs(node.children or {}) do
    emit_block(c, out)
  end
end

local function emit_paragraph(node, out)
  out[#out + 1] = emit_inline(node.inline)
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
  end
  -- other kinds: silently drop for now (will be added in subsequent tasks)
end

function M.render(ast, _opts)
  if not ast then
    return ""
  end
  local out = {}
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
