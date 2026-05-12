-- Document AST -> CommonMark / GFM string.
--
-- Companion to from_org.lua.  Renders every AST kind that from_org
-- emits, with GFM extensions (tables, strikethrough, task-list
-- checkboxes) plus pandoc-style math ($...$ / $$...$$) and footnotes
-- ([^label] / [^label]: body).

local M = {}

local function emit_inline(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "emphasis" then
      local inner = emit_inline(n.content)
      local s = n.style
      if s == "bold" then
        out[#out + 1] = "**" .. inner .. "**"
      elseif s == "italic" then
        out[#out + 1] = "*" .. inner .. "*"
      elseif s == "underline" then
        out[#out + 1] = "<u>" .. inner .. "</u>"
      elseif s == "strike" then
        out[#out + 1] = "~~" .. inner .. "~~"
      elseif s == "verbatim" or s == "code" then
        out[#out + 1] = "`" .. inner .. "`"
      else
        out[#out + 1] = inner
      end
    end
  end
  return table.concat(out)
end

local function emit_headline(node, out)
  local level = math.min(6, math.max(1, node.level or 1))
  local title = emit_inline(node.title or {})
  out[#out + 1] = string.rep("#", level) .. " " .. title
  out[#out + 1] = ""
end

local function emit_paragraph(node, out)
  out[#out + 1] = emit_inline(node.inline or {})
  out[#out + 1] = ""
end

local function emit_block(node, out)
  local kind = node.kind
  if kind == "headline" then
    emit_headline(node, out)
    for _, c in ipairs(node.children or {}) do
      emit_block(c, out)
    end
  elseif kind == "paragraph" then
    emit_paragraph(node, out)
  end
  -- Other kinds drop silently; per-kind branches added in subsequent tasks.
end

local function collapse_blank_runs(lines)
  local collapsed = {}
  local prev_blank = false
  for _, l in ipairs(lines) do
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
  return collapsed
end

function M.render(doc, opts)
  opts = opts or {}
  local out = {}
  for _, c in ipairs(doc.children or {}) do
    emit_block(c, out)
  end
  local collapsed = collapse_blank_runs(out)
  return table.concat(collapsed, "\n") .. "\n"
end

-- Expose internals for tests.
M._emit_inline = emit_inline
M._emit_block = emit_block

return M
