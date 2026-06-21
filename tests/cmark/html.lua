-- Test-facing AST -> CommonMark reference HTML renderer.  Distinct from
-- organ.ast.to_html (which renders org semantics): this exists solely to
-- diff from_md output against the official CommonMark/GFM example suites,
-- which define conformance as HTML.  Grows one node kind per parser stage.
local M = {}

local DISALLOWED = {
  title = true,
  textarea = true,
  style = true,
  xmp = true,
  iframe = true,
  noembed = true,
  noframes = true,
  script = true,
  plaintext = true,
}

-- GFM tagfilter: replace the leading `<` of a disallowed raw-HTML tag (open or
-- close) with `&lt;`.  Tag-name match is case-insensitive; the delimiter after
-- the name must be `>`, whitespace, or `/`.  All other markup is left as-is.
local function tagfilter(s)
  return (
    s:gsub("<(/?)(%a[%w]*)([ \t\r\n/>])", function(slash, name, delim)
      if DISALLOWED[name:lower()] then
        return "&lt;" .. slash .. name .. delim
      end
    end)
  )
end

local tagfilter_on = false

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
    elseif n.kind == "emphasis" and n.style == "code" then
      local content = (n.content and n.content[1] and n.content[1].text) or ""
      out[#out + 1] = "<code>" .. escape(content) .. "</code>"
    elseif n.kind == "emphasis" and n.style == "italic" then
      out[#out + 1] = "<em>" .. inline(n.content) .. "</em>"
    elseif n.kind == "emphasis" and n.style == "bold" then
      out[#out + 1] = "<strong>" .. inline(n.content) .. "</strong>"
    elseif n.kind == "emphasis" and n.style == "strike" then
      out[#out + 1] = "<del>" .. inline(n.content) .. "</del>"
    elseif n.kind == "linebreak" then
      out[#out + 1] = "<br />\n"
    elseif n.kind == "link" and n.form == "autolink" then
      out[#out + 1] = '<a href="'
        .. escape(n.target or "")
        .. '">'
        .. escape(n.description or "")
        .. "</a>"
    elseif n.kind == "link" then
      out[#out + 1] = '<a href="'
        .. escape(n.target or "")
        .. '"'
        .. (n.title and ' title="' .. escape(n.title) .. '"' or "")
        .. ">"
        .. inline(n.description)
        .. "</a>"
    elseif n.kind == "image" then
      out[#out + 1] = '<img src="'
        .. escape(n.target or "")
        .. '" alt="'
        .. escape(n.alt or "")
        .. '"'
        .. (n.title and ' title="' .. escape(n.title) .. '"' or "")
        .. " />"
    elseif n.kind == "raw_inline" then
      local t = n.text or ""
      out[#out + 1] = tagfilter_on and tagfilter(t) or t
    end
    -- later stages: emphasis (bold/italic), link, etc.
  end
  return table.concat(out)
end

local block, list_item, table_node

-- GFM table renderer.  The first non-separator row is the header (thead); the
-- remaining non-separator rows are data rows (tbody, omitted when there are
-- none).  Column alignment comes from `node.alignments`: "l"/"r"/"c" map to an
-- align="left"/"right"/"center" attribute; `false`/nil emits no attribute.
local ALIGN_ATTR = { l = "left", r = "right", c = "center" }

table_node = function(node, out)
  local rows = node.rows or {}
  local aligns = node.alignments or {}
  local data = {}
  local header
  for _, row in ipairs(rows) do
    if row.sep ~= true then
      if not header then
        header = row
      else
        data[#data + 1] = row
      end
    end
  end
  if not header then
    return
  end
  local function cell(tag, content, col)
    local a = ALIGN_ATTR[aligns[col]]
    local attr = a and (' align="' .. a .. '"') or ""
    return "<" .. tag .. attr .. ">" .. inline(content) .. "</" .. tag .. ">\n"
  end
  out[#out + 1] = "<table>\n<thead>\n<tr>\n"
  for c, content in ipairs(header.cells) do
    out[#out + 1] = cell("th", content, c)
  end
  out[#out + 1] = "</tr>\n</thead>\n"
  if #data > 0 then
    out[#out + 1] = "<tbody>\n"
    for _, row in ipairs(data) do
      out[#out + 1] = "<tr>\n"
      for c, content in ipairs(row.cells) do
        out[#out + 1] = cell("td", content, c)
      end
      out[#out + 1] = "</tr>\n"
    end
    out[#out + 1] = "</tbody>\n"
  end
  out[#out + 1] = "</table>\n"
end

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
    local b = node.body or ""
    out[#out + 1] = tagfilter_on and tagfilter(b) or b
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
      list_item(item, out, node.loose)
    end
    out[#out + 1] = node.ordered and "</ol>\n" or "</ul>\n"
  elseif node.kind == "table" then
    table_node(node, out)
  end
end

-- Render a list item.  In a loose list every paragraph child is wrapped in
-- <p>...</p> on its own line and the item is `<li>\n` ... `</li>\n`.  In a tight
-- list a lone paragraph child renders as bare inline text inside `<li>`...`</li>`
-- and other children render normally.
--
-- GFM task list: when item.checkbox is set, a disabled <input> precedes content.
local function checkbox_prefix(item)
  if item.checkbox == "done" then
    return '<input checked="" disabled="" type="checkbox"> '
  elseif item.checkbox == "todo" then
    return '<input disabled="" type="checkbox"> '
  end
  return ""
end

list_item = function(item, out, loose)
  local children = item.content or {}
  local prefix = checkbox_prefix(item)
  if loose then
    out[#out + 1] = "<li>\n"
    for _, c in ipairs(children) do
      if c.kind == "paragraph" then
        out[#out + 1] = "<p>" .. prefix .. inline(c.inline) .. "</p>\n"
      else
        block(c, out)
      end
      prefix = ""
    end
    out[#out + 1] = "</li>\n"
    return
  end
  if #children == 1 and children[1].kind == "paragraph" then
    out[#out + 1] = "<li>" .. prefix .. inline(children[1].inline) .. "</li>\n"
    return
  end
  out[#out + 1] = "<li>"
  local body = {}
  for i, c in ipairs(children) do
    if c.kind == "paragraph" then
      body[#body + 1] = prefix .. inline(c.inline)
      if i < #children then
        body[#body + 1] = "\n"
      end
    else
      if i == 1 then
        body[#body + 1] = "\n"
      end
      block(c, body)
    end
    prefix = ""
  end
  out[#out + 1] = table.concat(body)
  out[#out + 1] = "</li>\n"
end

function M.render(doc, opts)
  tagfilter_on = opts ~= nil and opts.tagfilter == true
  local out = {}
  for _, c in ipairs(doc.children or {}) do
    block(c, out)
  end
  return table.concat(out)
end

return M
