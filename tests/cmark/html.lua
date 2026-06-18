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

local function block(node, out)
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
  end
  -- later stages: list, block, table, ...
end

function M.render(doc)
  local out = {}
  for _, c in ipairs(doc.children or {}) do
    block(c, out)
  end
  return table.concat(out)
end

return M
