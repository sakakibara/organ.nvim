-- Organ document AST.
--
-- A small, format-neutral tree built from any markup source (org,
-- markdown, asciidoc, rst, ...) and rendered back to any of them.
-- Round-trips through `to_org` are intentionally lossy: format-
-- specific metadata (TODO keywords, priority cookies, drawers,
-- frontmatter, role attributes) drops on the way out unless the
-- target format also expresses it.
--
-- Node shape:
--   { kind = "<kind>", ...kind-specific fields..., children = {...} }
-- Block nodes carry `children` (list of further block / inline nodes);
-- inline nodes that wrap content carry `content` (list of inline nodes).
-- A `text` inline is a leaf.
--
-- This module exposes ONLY constructors / validators / walkers.  The
-- per-format encoders live in sibling modules (`from_org`, `to_org`,
-- `from_markdown`, `to_markdown`, ...).

local M = {}

-- Any block node may also carry an optional `affiliated` field: an ordered
-- list of { name = "NAME"|"CAPTION"|"ATTR_*"|..., value = "string" } drawn
-- from the `#+KEYWORD:` lines that immediately precede it.

-- Block kinds: appear in `children` of `document` or another block.
M.BLOCK = {
  document = true, -- root: { children = {...} }
  headline = true, -- { level, todo?, priority?, tags?, planning?, properties?, title=inline[], children }
  paragraph = true, -- { inline = inline[] }
  list = true, -- { ordered, items = list_item[] }
  list_item = true, -- { checkbox = "todo"|"done"|"part"|nil, content = block[] }
  code_block = true, -- { language?, params?, body = "string" }
  block = true, -- { style, body? = "string", content? = block[], backend? = "string" }
  table = true, -- { alignments = ("l"|"r"|"c")[], rows = (...)[], tblfm? = ("string")[] }
  rule = true, -- horizontal rule (no fields)
  directive = true, -- { name = "TITLE", value = "string" }
  drawer = true, -- { name = "string", body = "string" } (verbatim inner lines)
  footnote_definition = true, -- { label = "string", content = block[] }
  comment = true, -- { body = "string" } (line / multi-line org `# ` comment)
}

-- Inline kinds: appear in `inline` / `title` / `content` arrays.
M.INLINE = {
  text = true, -- { text = "string" }
  emphasis = true, -- { style = "bold"|"italic"|"underline"|"strike"|"verbatim"|"code", content = inline[] }
  link = true, -- { target = "string", description = inline[] | nil }
  image = true, -- { target = "string", alt = "string"|nil }
  footnote_ref = true, -- { label = "string" }
  math = true, -- { display = bool, body = "string" }
  linebreak = true, -- explicit hard break (no fields)
}

-- Valid? Lightweight invariant check; raises on misuse during dev.
-- Returns true on valid trees, otherwise (false, "what's wrong").
local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
  end
  return true
end

local function validate_node(n, where)
  where = where or "<root>"
  if type(n) ~= "table" then
    return false, where .. ": node must be a table, got " .. type(n)
  end
  if not n.kind then
    return false, where .. ": node missing `kind`"
  end
  if not (M.BLOCK[n.kind] or M.INLINE[n.kind]) then
    return false, where .. ": unknown kind " .. tostring(n.kind)
  end
  return true
end

function M.validate(root)
  local stack = { { node = root, where = "<root>" } }
  while #stack > 0 do
    local frame = table.remove(stack)
    local ok, err = validate_node(frame.node, frame.where)
    if not ok then
      return false, err
    end
    local n = frame.node
    if n.children then
      if not is_array(n.children) then
        return false, frame.where .. ".children: not an array"
      end
      for i, c in ipairs(n.children) do
        stack[#stack + 1] = { node = c, where = frame.where .. ".children[" .. i .. "]" }
      end
    end
    if n.content then
      if not is_array(n.content) then
        return false, frame.where .. ".content: not an array"
      end
      for i, c in ipairs(n.content) do
        stack[#stack + 1] = { node = c, where = frame.where .. ".content[" .. i .. "]" }
      end
    end
    if n.inline then
      if not is_array(n.inline) then
        return false, frame.where .. ".inline: not an array"
      end
      for i, c in ipairs(n.inline) do
        stack[#stack + 1] = { node = c, where = frame.where .. ".inline[" .. i .. "]" }
      end
    end
    if n.title then
      if not is_array(n.title) then
        return false, frame.where .. ".title: not an array"
      end
      for i, c in ipairs(n.title) do
        stack[#stack + 1] = { node = c, where = frame.where .. ".title[" .. i .. "]" }
      end
    end
  end
  return true
end

-- Constructors -- shorthand so callers don't have to spell out `kind`.
function M.document(children)
  return { kind = "document", children = children or {} }
end

-- headline:
--   level    -- integer, depth in the outline (1 = top level)
--   todo     -- optional string, TODO keyword (e.g. "TODO", "DONE")
--   priority -- optional string, one char ("A".."Z") from `[#X]` cookie
--   tags     -- optional list of strings, trailing `:a:b:` tags
--   title    -- list of inline nodes parsed from the headline text
--   children -- list of block nodes for the headline's section content
--   planning -- optional table; raw timestamp strings keyed by entry kind:
--                { scheduled = "<...>", deadline = "<...>", closed = "[...]" }
--              Brackets preserved verbatim from source; missing entries nil.
--   properties -- optional map of uppercase key -> string value from the
--                 headline's :PROPERTIES: ... :END: drawer.
function M.headline(opts)
  return {
    kind = "headline",
    level = opts.level or 1,
    todo = opts.todo,
    priority = opts.priority,
    tags = opts.tags,
    planning = opts.planning,
    properties = opts.properties,
    title = opts.title or {},
    children = opts.children or {},
  }
end

function M.paragraph(inline)
  return { kind = "paragraph", inline = inline or {} }
end

function M.text(s)
  return { kind = "text", text = s or "" }
end

function M.emphasis(style, content)
  return { kind = "emphasis", style = style, content = content or {} }
end

function M.link(target, description)
  return { kind = "link", target = target, description = description }
end

function M.code_block(language, body, params)
  return { kind = "code_block", language = language, params = params, body = body or "" }
end

function M.list(ordered, items)
  return { kind = "list", ordered = ordered and true or false, items = items or {} }
end

function M.list_item(opts)
  return { kind = "list_item", checkbox = opts.checkbox, content = opts.content or {} }
end

function M.block(style, opts)
  opts = opts or {}
  return {
    kind = "block",
    style = style,
    body = opts.body,
    content = opts.content,
    backend = opts.backend,
  }
end

function M.drawer(name, body)
  return { kind = "drawer", name = name, body = body }
end

function M.comment(body)
  return { kind = "comment", body = body }
end

function M.directive(name, value)
  return { kind = "directive", name = name, value = value or "" }
end

function M.footnote_definition(label, content)
  return { kind = "footnote_definition", label = label, content = content or {} }
end

function M.rule()
  return { kind = "rule" }
end

function M.linebreak()
  return { kind = "linebreak" }
end

-- Walk: depth-first pre-order traversal.  fn(node, parent, key, idx).
-- Used by tests + per-format renderers that don't want to build their
-- own dispatch.
function M.walk(root, fn)
  local function go(n, parent, key, idx)
    if type(n) ~= "table" or not n.kind then
      return
    end
    fn(n, parent, key, idx)
    for _, slot in ipairs({ "children", "content", "inline", "title" }) do
      if n[slot] then
        for i, c in ipairs(n[slot]) do
          go(c, n, slot, i)
        end
      end
    end
  end
  go(root, nil, nil, nil)
end

return M
