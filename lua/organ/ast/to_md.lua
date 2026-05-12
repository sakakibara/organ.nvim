-- Document AST -> CommonMark / GFM string.
--
-- Companion to from_org.lua.  Renders every AST kind that from_org
-- emits, with GFM extensions (tables, strikethrough, task-list
-- checkboxes) plus pandoc-style math ($...$ / $$...$$) and footnotes
-- ([^label] / [^label]: body).

local M = {}

local emit_inline
local emit_block

function emit_inline(nodes)
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
    elseif n.kind == "link" then
      local target = n.target or ""
      if n.description and #n.description > 0 then
        out[#out + 1] = "[" .. emit_inline(n.description) .. "](" .. target .. ")"
      else
        out[#out + 1] = "[" .. target .. "](" .. target .. ")"
      end
    elseif n.kind == "image" then
      local target = n.target or ""
      local alt = n.alt and n.alt ~= "" and n.alt or target
      out[#out + 1] = "![" .. alt .. "](" .. target .. ")"
    elseif n.kind == "footnote_ref" then
      out[#out + 1] = "[^" .. (n.label or "") .. "]"
    elseif n.kind == "math" then
      if n.display then
        out[#out + 1] = "$$" .. (n.body or "") .. "$$"
      else
        out[#out + 1] = "$" .. (n.body or "") .. "$"
      end
    elseif n.kind == "linebreak" then
      out[#out + 1] = "  \n"
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

local function emit_list(node, out, depth)
  depth = depth or 0
  local indent = string.rep("  ", depth)
  local n = 1
  for _, item in ipairs(node.items or {}) do
    local marker = node.ordered and (n .. ".") or "-"
    local checkbox = ""
    if item.checkbox == "todo" then
      checkbox = "[ ] "
    elseif item.checkbox == "done" then
      checkbox = "[x] "
    elseif item.checkbox == "part" then
      checkbox = "[ ] "
    end
    -- The list_item's content is a list of blocks; render the first
    -- paragraph on the marker line, then recurse for nested lists +
    -- continuation paragraphs.
    local first = true
    for _, b in ipairs(item.content or {}) do
      if b.kind == "paragraph" then
        local txt = emit_inline(b.inline)
        if first then
          out[#out + 1] = indent .. marker .. " " .. checkbox .. txt
          first = false
        else
          out[#out + 1] = indent .. "  " .. txt
        end
      elseif b.kind == "list" then
        emit_list(b, out, depth + 1)
      end
    end
    n = n + 1
  end
  out[#out + 1] = ""
end

local function emit_code_block(node, out)
  out[#out + 1] = "```" .. (node.language or "")
  for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  -- Drop the trailing empty produced by the splitter when body ends
  -- with a newline (or is empty) -- the closing fence on its own line
  -- is what we want, not a blank line before it.
  if out[#out] == "" then
    out[#out] = nil
  end
  out[#out + 1] = "```"
  out[#out + 1] = ""
end

-- Org-style block kinds (quote / verse / example / export).
-- Named emit_org_block to disambiguate from the AST kind "block".
local function emit_org_block(node, out)
  local style = node.style
  if style == "quote" then
    -- Render content into a sub-buffer, then prefix each line with "> ".
    local sub = {}
    for _, b in ipairs(node.content or {}) do
      emit_block(b, sub)
    end
    -- Drop the trailing empty the inner emitters add so we don't get
    -- a `> ` on a blank line.
    while #sub > 0 and sub[#sub] == "" do
      sub[#sub] = nil
    end
    for _, line in ipairs(sub) do
      if line == "" then
        out[#out + 1] = ">"
      else
        out[#out + 1] = "> " .. line
      end
    end
    out[#out + 1] = ""
  elseif style == "verse" or style == "example" then
    out[#out + 1] = "```"
    for line in ((node.body or "") .. "\n"):gmatch("([^\n]*)\n") do
      out[#out + 1] = line
    end
    if out[#out] == "" then
      out[#out] = nil
    end
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  -- export and unknown styles drop silently.
end

function emit_block(node, out)
  local kind = node.kind
  if kind == "headline" then
    emit_headline(node, out)
    for _, c in ipairs(node.children or {}) do
      emit_block(c, out)
    end
  elseif kind == "paragraph" then
    emit_paragraph(node, out)
  elseif kind == "list" then
    emit_list(node, out, 0)
  elseif kind == "code_block" then
    emit_code_block(node, out)
  elseif kind == "block" then
    emit_org_block(node, out)
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
