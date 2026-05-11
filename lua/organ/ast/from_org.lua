-- Org tree-sitter tree -> document AST.
--
-- Phase 1a: covers the common case (document with headlines, paragraphs,
-- lists, code blocks, basic emphasis + links).  More node kinds will
-- be added as the per-format renderers need them.

local A = require("organ.ast")

local M = {}

local function get_text(node, src)
  local sr, sc, er, ec = node:range()
  if sr == er then
    return src[sr + 1] and src[sr + 1]:sub(sc + 1, ec) or ""
  end
  local out = { src[sr + 1] and src[sr + 1]:sub(sc + 1) or "" }
  for r = sr + 2, er do
    out[#out + 1] = src[r] or ""
  end
  out[#out + 1] = src[er + 1] and src[er + 1]:sub(1, ec) or ""
  return table.concat(out, "\n")
end

local function children(node)
  local out = {}
  for c in node:iter_children() do
    out[#out + 1] = c
  end
  return out
end

local function heading_level(node, src)
  local sr = node:start()
  local line = src[sr + 1] or ""
  return #(line:match("^(%*+)%s") or "")
end

local function clean_title(line, todo_keywords)
  -- Strip stars.
  line = line:gsub("^%*+%s+", "")
  -- Strip TODO keyword.
  local todo
  for _, kw in ipairs(todo_keywords or {}) do
    if kw ~= "|" then
      local pat = "^" .. kw .. "(%s+)"
      if line:match(pat) then
        todo = kw
        line = line:gsub(pat, "")
        break
      end
    end
  end
  -- Strip priority cookie.
  local priority = line:match("^%[#(%w)%]%s*")
  if priority then
    line = line:gsub("^%[#%w%]%s*", "")
  end
  -- Strip trailing tags `:a:b:`.
  local tags_str = line:match("%s+(:[%w_:@]+:)%s*$")
  local tags
  if tags_str then
    tags = {}
    for t in tags_str:gmatch(":([%w_@]+)") do
      tags[#tags + 1] = t
    end
    line = line:gsub("%s+:[%w_:@]+:%s*$", "")
  end
  return line, todo, priority, tags
end

-- Parse one line of inline org text into AST inline nodes.
-- Phase 1a covers: emphasis (*bold*, /italic/, _und_, +strike+,
-- =verb=, ~code~) and links ([[target][desc]] / [[target]]).  Mixed
-- / nested emphasis falls back to plain text -- the emitters can
-- still reproduce it via to_org.
local function parse_inline(s)
  if s == "" then
    return {}
  end
  local out = {}
  local i = 1
  local cur = ""
  local function flush()
    if cur ~= "" then
      out[#out + 1] = A.text(cur)
      cur = ""
    end
  end
  while i <= #s do
    local c = s:sub(i, i)
    -- Try a link [[target][desc]] or [[target]].
    if c == "[" and s:sub(i + 1, i + 1) == "[" then
      local close = s:find("]]", i + 2, true)
      if close then
        local body = s:sub(i + 2, close - 1)
        local sep = body:find("][", 1, true)
        local target, desc
        if sep then
          target = body:sub(1, sep - 1)
          desc = parse_inline(body:sub(sep + 2))
        else
          target = body
        end
        flush()
        out[#out + 1] = A.link(target, desc)
        i = close + 2
        goto continue
      end
    end
    -- Try emphasis: paired delimiters (*, /, _, +, =, ~).
    -- For simplicity we accept any delimiter that has a matching
    -- close on the same line and contains no whitespace at the open
    -- side.  This is the common case; the org grammar is stricter
    -- but the diff rarely surfaces in real content.
    do
      local open = s:sub(i, i)
      local style
      if open == "*" then
        style = "bold"
      elseif open == "/" then
        style = "italic"
      elseif open == "_" then
        style = "underline"
      elseif open == "+" then
        style = "strike"
      elseif open == "=" then
        style = "verbatim"
      elseif open == "~" then
        style = "code"
      end
      if style and s:sub(i + 1, i + 1) ~= " " and s:sub(i + 1, i + 1) ~= open then
        local close = s:find(open, i + 1, true)
        if close and close > i + 1 and s:sub(close - 1, close - 1) ~= " " then
          local inner = s:sub(i + 1, close - 1)
          flush()
          if style == "verbatim" or style == "code" then
            out[#out + 1] = A.emphasis(style, { A.text(inner) })
          else
            out[#out + 1] = A.emphasis(style, parse_inline(inner))
          end
          i = close + 1
          goto continue
        end
      end
    end
    cur = cur .. c
    i = i + 1
    ::continue::
  end
  flush()
  return out
end

-- Scan the whole buffer for #+TODO directives so headline TODO
-- keywords (extended sequences) parse correctly.  Mirrors the same
-- helper in export/markdown.lua etc.
local function scan_keywords(src)
  local kws = {
    "TODO",
    "NEXT",
    "WAITING",
    "WAIT",
    "HOLD",
    "STARTED",
    "PROJ",
    "DONE",
    "CANCELLED",
    "CANCELED",
    "CLOSED",
  }
  for _, line in ipairs(src) do
    local seq = line:match("^%s*#%+[Tt][Oo][Dd][Oo]:%s*(.+)$")
    if seq then
      kws = {}
      for word in seq:gmatch("(%S+)") do
        kws[#kws + 1] = word
      end
    end
  end
  return kws
end

-- Walk an org `headline` (TS node) emitting an AST headline.  Recurses
-- into children for sub-headlines / body content.  Body content is
-- everything between the title line and the next sub-headline.
local function emit_headline(node, src, todo_kws)
  local level = heading_level(node, src)
  local sr = node:start()
  local title_str, todo, priority, tags = clean_title(src[sr + 1] or "", todo_kws)
  local children_blocks = {}
  for c in node:iter_children() do
    if c:type() == "headline" then
      children_blocks[#children_blocks + 1] = emit_headline(c, src, todo_kws)
    elseif c:type() == "section" then
      for sc in c:iter_children() do
        local emit = M._emit_block_for_section_child
        local block = emit and emit(sc, src) or nil
        if block then
          if type(block) == "table" and block[1] and not block.kind then
            for _, b in ipairs(block) do
              children_blocks[#children_blocks + 1] = b
            end
          else
            children_blocks[#children_blocks + 1] = block
          end
        end
      end
    end
  end
  return A.headline({
    level = level,
    todo = todo,
    priority = priority,
    tags = tags,
    title = parse_inline(title_str),
    children = children_blocks,
  })
end

-- Convert a single TS node inside a `section` into an AST block (or
-- a list of blocks for special cases).  Returns nil for nodes we
-- don't yet model -- those just drop in this phase.
local function emit_section_child(node, src)
  local t = node:type()
  if t == "paragraph" then
    -- Collect raw text; parse_inline interprets emphasis + links.
    local sr, _, er, ec = node:range()
    local last_row = ec > 0 and er or er - 1
    local pieces = {}
    for r = sr, last_row do
      pieces[#pieces + 1] = src[r + 1] or ""
    end
    local raw = table.concat(pieces, "\n")
    return A.paragraph(parse_inline(raw))
  elseif t == "src_block" then
    local lang
    local lang_node = node:field("language")[1]
    if lang_node then
      lang = get_text(lang_node, src)
    end
    -- Collect body lines: everything between `#+begin_src ...` and
    -- `#+end_src` (exclusive).
    local sr, _, er = node:range()
    local body_lines = {}
    for r = sr + 1, er - 1 do
      body_lines[#body_lines + 1] = src[r + 1] or ""
    end
    return A.code_block(lang, table.concat(body_lines, "\n"))
  elseif t == "list" or t == "plain_list" then
    local items = {}
    local ordered = false
    for c in node:iter_children() do
      if c:type() == "list_item" then
        local item_text = get_text(c, src)
        local first = item_text:match("^([^\n]*)") or ""
        local prefix = first:match("^%s*([-+*]?[%w]*[%.])") or first:match("^%s*([-+*])")
        if prefix and prefix:match("^%d") then
          ordered = true
        end
        local checkbox
        if first:match("%[ %]") then
          checkbox = "todo"
        elseif first:match("%[[xX]%]") then
          checkbox = "done"
        elseif first:match("%[%-%]") then
          checkbox = "part"
        end
        local body = first:gsub("^%s*[-+*0-9.]+%s+", "")
        body = body:gsub("^%[[ xX%-]%]%s*", "")
        items[#items + 1] = A.list_item({
          checkbox = checkbox,
          content = { A.paragraph(parse_inline(body)) },
        })
      end
    end
    return A.list(ordered, items)
  elseif t == "keyword" then
    -- Tree-sitter `keyword` is `#+NAME: value`. Get the raw line and
    -- split on the first `:`.
    local sr = node:start()
    local line = src[sr + 1] or ""
    local name, value = line:match("^%s*#%+([%w_]+):%s*(.-)%s*$")
    if name then
      return A.directive(name:upper(), value or "")
    end
    return nil
  end
  return nil
end
M._emit_block_for_section_child = emit_section_child

-- Public entry: parse a buffer (passed as a bufnr or as a list of
-- source lines) and return a `document` AST.
function M.from_lines(src)
  local ok, parser = pcall(vim.treesitter.get_string_parser, table.concat(src, "\n"), "org")
  if not ok or not parser then
    return A.document({})
  end
  local tree = parser:parse()[1]
  if not tree then
    return A.document({})
  end
  local todo_kws = scan_keywords(src)
  local doc_children = {}
  for c in tree:root():iter_children() do
    if c:type() == "headline" then
      doc_children[#doc_children + 1] = emit_headline(c, src, todo_kws)
    elseif c:type() == "section" or c:type() == "zeroth_section" then
      for sc in c:iter_children() do
        local b = emit_section_child(sc, src)
        if b then
          doc_children[#doc_children + 1] = b
        end
      end
    end
  end
  return A.document(doc_children)
end

function M.from_buffer(bufnr)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.from_lines(lines)
end

return M
