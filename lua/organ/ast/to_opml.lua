-- OPML 2.0 renderer for organ.nvim AST.
--
-- Walks the AST building nested <outline> elements per headline.
-- Body content other than headlines is dropped; the first body
-- paragraph of each headline becomes its _note attribute.

local M = {}

local function escape_attr(s)
  if not s then
    return ""
  end
  s = s:gsub("&", "&amp;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub("\n", " ")
  return s
end

-- Flatten an inline list to plain text (markup discarded) -- used for
-- both the outline text= attribute and the _note attribute.
local function inline_text(nodes)
  if not nodes or #nodes == 0 then
    return ""
  end
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "text" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "emphasis" then
      out[#out + 1] = inline_text(n.content)
    elseif n.kind == "link" then
      if n.description and #n.description > 0 then
        out[#out + 1] = inline_text(n.description)
      else
        out[#out + 1] = n.target or ""
      end
    end
    -- math, image, footnote_ref, linebreak: drop entirely
  end
  return table.concat(out)
end

local function emit_headline(node, out, depth)
  local indent = string.rep("  ", depth + 2) -- +2 for <opml> + <body> indentation
  local title = inline_text(node.title)
  local attrs = string.format('text="%s"', escape_attr(title))

  -- _note = first paragraph child's inline text (single line).
  local note
  for _, c in ipairs(node.children or {}) do
    if c.kind == "paragraph" then
      local t = inline_text(c.inline)
      t = (t:gsub("\n.*$", "")):gsub("%s+$", ""):gsub("^%s+", "")
      if t ~= "" then
        note = t
      end
      break
    end
  end
  if note then
    attrs = attrs .. string.format(' _note="%s"', escape_attr(note))
  end

  out[#out + 1] = indent .. "<outline " .. attrs .. ">"
  for _, c in ipairs(node.children or {}) do
    if c.kind == "headline" then
      emit_headline(c, out, depth + 1)
    end
  end
  out[#out + 1] = indent .. "</outline>"
end

local function find_title(ast)
  if not ast or not ast.children then
    return nil
  end
  for _, c in ipairs(ast.children) do
    if c.kind == "directive" and c.name == "TITLE" then
      return c.value
    end
  end
  return nil
end

function M.render(ast, _opts)
  if not ast then
    return ""
  end
  local title = find_title(ast) or "Org outline"
  local out = {
    [[<?xml version="1.0" encoding="UTF-8"?>]],
    [[<opml version="2.0">]],
    "  <head>",
    "    <title>" .. escape_attr(title) .. "</title>",
    "  </head>",
    "  <body>",
  }
  for _, c in ipairs(ast.children or {}) do
    if c.kind == "headline" then
      emit_headline(c, out, 0)
    end
  end
  out[#out + 1] = "  </body>"
  out[#out + 1] = "</opml>"
  return table.concat(out, "\n") .. "\n"
end

M._inline_text = inline_text
M._escape_attr = escape_attr

return M
