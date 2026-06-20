-- Test-facing AST -> CommonMark reference HTML renderer.  Distinct from
-- organ.ast.to_html (which renders org semantics): this exists solely to
-- diff from_md output against the official CommonMark/GFM example suites,
-- which define conformance as HTML.  Grows one node kind per parser stage.
local M = {}

local function escape(s)
  return (
    s:gsub('[&<>"]', {
      ["&"] = "&amp;",
      ["<"] = "&lt;",
      [">"] = "&gt;",
      ['"'] = "&quot;",
    })
  )
end

local function inline(nodes)
  local out = {}
  for _, n in ipairs(nodes or {}) do
    if n.kind == "text" then
      out[#out + 1] = escape(n.text or "")
    end
    -- later stages: emphasis, link, code, etc.
  end
  return table.concat(out)
end

local block, list_item

function block(node, out)
  if node.kind == "paragraph" then
    out[#out + 1] = "<p>" .. inline(node.inline) .. "</p>\n"
  elseif node.kind == "headline" then
    local lvl = node.level
    out[#out + 1] = "<h" .. lvl .. ">" .. inline(node.title) .. "</h" .. lvl .. ">\n"
  elseif node.kind == "rule" then
    out[#out + 1] = "<hr />\n"
  elseif node.kind == "code_block" then
    local attr = (node.language and node.language ~= "")
        and (' class="language-' .. node.language .. '"')
      or ""
    out[#out + 1] = "<pre><code" .. attr .. ">" .. escape(node.body or "") .. "</code></pre>\n"
  elseif node.kind == "block" and node.style == "quote" then
    out[#out + 1] = "<blockquote>\n"
    for _, c in ipairs(node.content or {}) do
      block(c, out)
    end
    out[#out + 1] = "</blockquote>\n"
  elseif node.kind == "block" and node.style == "export" and node.backend == "html" then
    out[#out + 1] = node.body or ""
  elseif node.kind == "list" then
    local items = node.items or {}
    if node.ordered then
      local first = items[1] and tonumber(items[1].counter)
      local attr = (first and first ~= 1) and (' start="' .. first .. '"') or ""
      out[#out + 1] = "<ol" .. attr .. ">\n"
    else
      out[#out + 1] = "<ul>\n"
    end
    for _, item in ipairs(items) do
      list_item(item, out)
    end
    out[#out + 1] = node.ordered and "</ol>\n" or "</ul>\n"
  end
  -- later stages: table, ...
end

-- Render a list item (tight): a lone paragraph child renders as its inline text
-- with no <p> wrapper; other children render normally; a nested list follows the
-- item's text on its own lines.
list_item = function(item, out)
  local children = item.content or {}
  if #children == 1 and children[1].kind == "paragraph" then
    out[#out + 1] = "<li>" .. inline(children[1].inline) .. "</li>\n"
    return
  end
  out[#out + 1] = "<li>"
  local body = {}
  for i, c in ipairs(children) do
    if c.kind == "paragraph" then
      body[#body + 1] = inline(c.inline)
      if i < #children then
        body[#body + 1] = "\n"
      end
    else
      if i == 1 then
        body[#body + 1] = "\n"
      end
      block(c, body)
    end
  end
  out[#out + 1] = table.concat(body)
  out[#out + 1] = "</li>\n"
end

function M.render(doc)
  local out = {}
  for _, c in ipairs(doc.children or {}) do
    block(c, out)
  end
  return table.concat(out)
end

return M
