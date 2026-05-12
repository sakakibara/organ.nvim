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

local function emit_list(node, out, depth)
  depth = depth or 0
  local indent = string.rep("  ", depth)
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
        local txt = emit_inline(b.inline)
        if first then
          out[#out + 1] = indent .. "- " .. checkbox .. txt
          first = false
        else
          out[#out + 1] = indent .. "  " .. txt
        end
      elseif b.kind == "list" then
        emit_list(b, out, depth + 1)
      end
    end
  end
  out[#out + 1] = ""
end

local function emit_code_block(node, out)
  for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = "    " .. line
  end
  if out[#out] == "    " then
    out[#out] = nil
  end
  out[#out + 1] = ""
end

local function emit_org_block(node, out)
  local style = node.style
  if style == "verse" or style == "example" then
    for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = "    " .. line
    end
    if out[#out] == "    " then
      out[#out] = nil
    end
    out[#out + 1] = ""
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
  end
  -- export / unknown styles drop silently.
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
    emit_list(node, out, 0)
  elseif kind == "code_block" then
    emit_code_block(node, out)
  elseif kind == "block" then
    emit_org_block(node, out)
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
