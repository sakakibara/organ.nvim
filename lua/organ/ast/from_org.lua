-- Org tree-sitter tree -> document AST.
--
-- Covers headlines, paragraphs, lists, code blocks, basic emphasis +
-- links, directives (#+KEYWORD: value), horizontal rules, blocks
-- (quote / verse / example / export), tables, free-standing images,
-- inline + display math, and footnotes (inline ref + block definition).
-- This is the input layer for organ.pdf and (eventually) the other
-- export backends as they migrate from direct tree-sitter walking.

local A = require("organ.ast")

local M = {}

local emit_section_child

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

local function block_body(node, src)
  local sr, _, er = node:range()
  local lines = {}
  for r = sr + 1, er - 1 do
    lines[#lines + 1] = src[r + 1] or ""
  end
  return table.concat(lines, "\n")
end

-- Image-target sniff.  An image extension is one of the common bitmap
-- / vector extensions, case-insensitive.
local IMAGE_EXT = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  svg = true,
  webp = true,
  bmp = true,
  tiff = true,
  tif = true,
}
local function is_image_target(target)
  if type(target) ~= "string" then
    return false
  end
  local ext = target:match("%.([%w]+)$")
  return ext and IMAGE_EXT[ext:lower()] or false
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

-- Parse an inline org text fragment into AST inline nodes by walking
-- the `org_inline` tree-sitter grammar -- the same grammar conceal,
-- decoration, and folding already use.  Each grammar node maps to a
-- typed inline node; any node without a dedicated mapping survives as
-- a verbatim `raw_inline` so nothing is lost.
local parse_inline
do
  local function latex_to_math(text)
    if text:sub(1, 2) == "$$" then
      return A.math({ display = true, body = text:sub(3, -3), style = "dollar" })
    elseif text:sub(1, 1) == "$" then
      return A.math({ display = false, body = text:sub(2, -2), style = "dollar" })
    elseif text:sub(1, 2) == "\\(" then
      return A.math({ display = false, body = text:sub(3, -3), style = "paren" })
    elseif text:sub(1, 2) == "\\[" then
      return A.math({ display = true, body = text:sub(3, -3), style = "bracket" })
    end
    return A.raw_inline(text)
  end

  local EMPHASIS = {
    bold = "bold",
    italic = "italic",
    underline = "underline",
    strike = "strike",
  }
  local TIMESTAMP = {
    timestamp_active = "active",
    timestamp_inactive = "inactive",
    timestamp_range_active = "range_active",
    timestamp_range_inactive = "range_inactive",
    timestamp_diary = "diary",
  }

  parse_inline = function(s)
    if s == "" then
      return {}
    end
    local ok, parser = pcall(vim.treesitter.get_string_parser, s, "org_inline")
    if not ok or not parser then
      return { A.text(s) }
    end
    local tree = parser:parse()[1]
    if not tree then
      return { A.text(s) }
    end

    local function txt(node)
      return vim.treesitter.get_node_text(node, s)
    end

    local node_to_inline

    local function map_children(node)
      local out = {}
      for c in node:iter_children() do
        if c:named() then
          out[#out + 1] = node_to_inline(c)
        end
      end
      return out
    end

    local function child_text(node, field)
      for c in node:iter_children() do
        if c:named() and c:type() == field then
          return txt(c)
        end
      end
      return nil
    end

    node_to_inline = function(node)
      local t = node:type()
      if t == "plain_text" then
        return A.text(txt(node))
      elseif EMPHASIS[t] then
        return A.emphasis(EMPHASIS[t], map_children(node))
      elseif t == "verbatim" or t == "code" then
        local raw = txt(node)
        return A.emphasis(t, { A.text(raw:sub(2, -2)) })
      elseif t == "link_regular" then
        local target = child_text(node, "link_target") or ""
        local desc_text = child_text(node, "link_description")
        local desc = desc_text and parse_inline(desc_text) or nil
        return A.link(target, desc)
      elseif t == "latex_fragment" then
        return latex_to_math(txt(node))
      elseif t == "entity" then
        return A.entity(txt(node):sub(2))
      elseif t == "subscript" then
        local inner = txt(node):match("^_%{(.*)%}$") or txt(node):sub(2)
        return A.subscript(parse_inline(inner))
      elseif t == "superscript" then
        local inner = txt(node):match("^%^%{(.*)%}$") or txt(node):sub(2)
        return A.superscript(parse_inline(inner))
      elseif t == "statistics_cookie" then
        return A.statistics_cookie(txt(node))
      elseif TIMESTAMP[t] then
        return A.timestamp(txt(node), TIMESTAMP[t])
      elseif t == "target" then
        return A.target(txt(node):match("^<<(.*)>>$") or txt(node))
      elseif t == "macro" then
        local name = child_text(node, "macro_name") or ""
        local args = {}
        for c in node:iter_children() do
          if c:named() and c:type() == "macro_argument" then
            args[#args + 1] = txt(c)
          end
        end
        return A.macro(name, args)
      elseif t == "footnote_ref" then
        local label = child_text(node, "footnote_label")
        local body = child_text(node, "footnote_body")
        local content = body and parse_inline(body) or nil
        return A.footnote_ref(label, content)
      elseif t == "line_break" then
        return A.linebreak()
      else
        return A.raw_inline(txt(node))
      end
    end

    return map_children(tree:root())
  end
end

local function parse_table(node, src)
  local sr, _, er = node:range()
  local rows = {}
  local ncols = 0
  local cookie_aligns
  for r = sr, er - 1 do
    local line = src[r + 1] or ""
    if line:match("^%s*|%-") then
      rows[#rows + 1] = { sep = true, cells = {} }
    elseif line:match("^%s*|") then
      local cells = {}
      for cell in line:gmatch("|([^|]*)") do
        local trimmed = cell:gsub("^%s+", ""):gsub("%s+$", "")
        cells[#cells + 1] = trimmed
      end
      -- Drop trailing empties (org tables end on `|`).
      while #cells > 0 and cells[#cells] == "" do
        cells[#cells] = nil
      end
      if #cells > ncols then
        ncols = #cells
      end
      -- A row whose every non-empty cell is an alignment cookie (<l>/<r>/<c>)
      -- sets column alignment. The row stays in `rows` as data, so it
      -- round-trips; we only populate the semantic alignments field.
      if not cookie_aligns then
        local all_cookies, any = true, false
        local cand = {}
        for i, c in ipairs(cells) do
          if c == "" then
            cand[i] = "l"
          else
            local a = c:match("^<([lrc])>$")
            if a then
              cand[i] = a
              any = true
            else
              all_cookies = false
              break
            end
          end
        end
        if all_cookies and any then
          cookie_aligns = cand
        end
      end
      -- Parse each cell as inline.
      local parsed = {}
      for _, c in ipairs(cells) do
        parsed[#parsed + 1] = parse_inline(c)
      end
      rows[#rows + 1] = { cells = parsed, sep = false }
    end
  end
  local alignments = cookie_aligns or {}
  if not cookie_aligns then
    for _ = 1, ncols do
      alignments[#alignments + 1] = "l"
    end
  end
  return { kind = "table", alignments = alignments, rows = rows }
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

-- Tree-sitter splits a single user-visible org table into multiple
-- `table` grammar nodes whenever an interior `|---|` rule appears,
-- because each rule terminates a `table` production.  At the AST
-- level a table is "one user-visible table", so fold runs of
-- consecutive `table` blocks into one by concatenating their rows.
-- A single divider row is preserved between the merged segments so
-- the to_md/to_org emitters can decide whether to keep or drop it.
local function merge_adjacent_tables(blocks)
  local out = {}
  for _, b in ipairs(blocks) do
    local prev = out[#out]
    if b.kind == "table" and prev and prev.kind == "table" then
      -- Only insert the bridging separator when the previous segment does
      -- not already end on one (tree-sitter terminates a table grammar node
      -- on table_rule, so prev.rows already ends with sep=true in that case).
      local last = prev.rows[#prev.rows]
      if not (last and last.sep) then
        prev.rows[#prev.rows + 1] = { sep = true, cells = {} }
      end
      for _, r in ipairs(b.rows or {}) do
        prev.rows[#prev.rows + 1] = r
      end
      -- Widen alignments to the wider of the two segments.
      if #(b.alignments or {}) > #(prev.alignments or {}) then
        prev.alignments = b.alignments
      end
    else
      out[#out + 1] = b
    end
  end
  return out
end

-- Pull SCHEDULED / DEADLINE / CLOSED timestamps from a `planning` TS
-- node.  Returns { scheduled?, deadline?, closed? } with raw bracketed
-- timestamp strings, or nil when no entries were recognized.
local function extract_planning(planning_node, src)
  local out = {}
  local found = false
  for line_node in planning_node:iter_children() do
    if line_node:type() == "planning_line" then
      for entry in line_node:iter_children() do
        if entry:type() == "planning_entry" then
          local kw_node = entry:field("keyword")[1]
          local ts_node = entry:field("timestamp")[1]
          if kw_node and ts_node then
            local kw = get_text(kw_node, src):upper()
            local ts = get_text(ts_node, src)
            if kw == "SCHEDULED" then
              out.scheduled = ts
              found = true
            elseif kw == "DEADLINE" then
              out.deadline = ts
              found = true
            elseif kw == "CLOSED" then
              out.closed = ts
              found = true
            end
          end
        end
      end
    end
  end
  if not found then
    return nil
  end
  return out
end

-- Pull `:KEY: value` pairs from a `property_drawer` TS node into a
-- uppercase-keyed map, or nil if the drawer is empty.
local function extract_properties(drawer_node, src)
  local out = {}
  local found = false
  for prop in drawer_node:iter_children() do
    if prop:type() == "node_property" then
      local name_node = prop:field("name")[1]
      local value_node = prop:field("value")[1]
      if name_node then
        local key = get_text(name_node, src):upper()
        local value = value_node and get_text(value_node, src) or ""
        out[key] = value
        found = true
      end
    end
  end
  if not found then
    return nil
  end
  return out
end

-- Process a `section` node's children into a list of AST blocks, plus
-- hoisted planning / properties. The single place section body is
-- assembled (shared by emit_headline and from_lines), so affiliated-
-- keyword and #+TBLFM association can live here.
local function emit_section_children(section_node, src)
  local planning, properties
  local items = {}
  for sc in section_node:iter_children() do
    local sct = sc:type()
    if sct == "planning" then
      planning = planning or extract_planning(sc, src)
    elseif sct == "property_drawer" then
      properties = properties or extract_properties(sc, src)
    elseif sct == "affiliated_keyword" then
      local name_node = sc:field("name")[1]
      local value_node = sc:field("value")[1]
      items[#items + 1] = {
        _marker = "affiliated",
        name = name_node and get_text(name_node, src):upper() or "",
        value = value_node and get_text(value_node, src) or "",
      }
    elseif sct == "formula" then
      local value_node = sc:field("value")[1]
      items[#items + 1] =
        { _marker = "formula", value = value_node and get_text(value_node, src) or "" }
    else
      local block = emit_section_child(sc, src)
      if block then
        if type(block) == "table" and block[1] and not block.kind then
          for _, b in ipairs(block) do
            items[#items + 1] = b
          end
        else
          items[#items + 1] = block
        end
      end
    end
  end
  local merged = merge_adjacent_tables(items)
  -- Attach buffered affiliated keywords forward to the next real block.
  -- formula markers back-attach to the preceding table; a standalone formula
  -- (no preceding table) falls back to a directive.
  local blocks = {}
  local pending = {}
  for _, it in ipairs(merged) do
    if it._marker == "affiliated" then
      pending[#pending + 1] = { name = it.name, value = it.value }
    elseif it._marker == "formula" then
      local last = blocks[#blocks]
      if last and last.kind == "table" then
        last.tblfm = last.tblfm or {}
        last.tblfm[#last.tblfm + 1] = it.value
      else
        blocks[#blocks + 1] = A.directive("TBLFM", it.value)
      end
    else
      if #pending > 0 then
        it.affiliated = pending
        pending = {}
      end
      blocks[#blocks + 1] = it
    end
  end
  -- Dangling affiliated keywords (no following element) stay as directives.
  for _, a in ipairs(pending) do
    blocks[#blocks + 1] = A.directive(a.name, a.value)
  end
  return blocks, planning, properties
end

local function emit_headline(node, src, todo_kws)
  local level = heading_level(node, src)
  local sr = node:start()
  local title_str, todo, priority, tags = clean_title(src[sr + 1] or "", todo_kws)
  local children_blocks = {}
  local planning, properties
  for c in node:iter_children() do
    if c:type() == "headline" then
      children_blocks[#children_blocks + 1] = emit_headline(c, src, todo_kws)
    elseif c:type() == "section" then
      local body, pl, pr = emit_section_children(c, src)
      planning = planning or pl
      properties = properties or pr
      for _, b in ipairs(body) do
        children_blocks[#children_blocks + 1] = b
      end
    end
  end
  return A.headline({
    level = level,
    todo = todo,
    priority = priority,
    tags = tags,
    planning = planning,
    properties = properties,
    title = parse_inline(title_str),
    children = children_blocks,
  })
end

-- Convert a single TS node inside a `section` into an AST block (or
-- a list of blocks for special cases).  Returns nil for node types we
-- don't yet model, which drop silently.  `planning` and
-- `property_drawer` are handled by emit_headline directly and never
-- reach this function.
emit_section_child = function(node, src)
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
    local inline = parse_inline(raw)
    -- Free-standing image rewrite: paragraph containing exactly one
    -- link whose target has an image extension (with optional
    -- leading/trailing whitespace text nodes) becomes a block-level
    -- image node.
    local non_ws_count, the_link = 0, nil
    for _, n in ipairs(inline) do
      if n.kind == "text" and n.text:match("^%s*$") then
        -- whitespace-only text; ignore
      elseif n.kind == "link" then
        non_ws_count = non_ws_count + 1
        the_link = n
      else
        non_ws_count = non_ws_count + 2 -- force the heuristic to fail
      end
    end
    if non_ws_count == 1 and the_link and is_image_target(the_link.target) then
      return {
        kind = "image",
        target = the_link.target,
        alt = the_link.description and (function()
          -- description is inline[]; flatten any text leaves into a string.
          local s = {}
          for _, d in ipairs(the_link.description) do
            if d.kind == "text" then
              s[#s + 1] = d.text
            end
          end
          local joined = table.concat(s)
          return joined ~= "" and joined or nil
        end)() or nil,
      }
    end
    return A.paragraph(inline)
  elseif t == "src_block" then
    local lang
    local lang_node = node:field("language")[1]
    if lang_node then
      lang = get_text(lang_node, src)
    end
    local params
    for c in node:iter_children() do
      if c:type() == "block_header_args" then
        params = get_text(c, src)
      end
    end
    -- Collect body lines: everything between `#+begin_src ...` and
    -- `#+end_src` (exclusive).
    local sr, _, er = node:range()
    local body_lines = {}
    for r = sr + 1, er - 1 do
      body_lines[#body_lines + 1] = src[r + 1] or ""
    end
    return A.code_block(lang, table.concat(body_lines, "\n"), params)
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
  elseif t == "horizontal_rule" then
    return A.rule()
  elseif t == "greater_block" then
    -- The org grammar emits `greater_block` for `#+begin_X` where X has
    -- no dedicated node type.  In practice that's `quote` plus any
    -- user-defined block.  Read the block name from the begin line.
    local sr = node:start()
    local name = (src[sr + 1] or ""):match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_([%w_]+)")
    if not name then
      return nil
    end
    name = name:lower()
    if name == "quote" then
      -- Quote: parse inner content as a sequence of paragraphs
      -- (blank-line delimited).  Each line runs through parse_inline
      -- so emphasis / links work.
      local body = block_body(node, src)
      local paragraphs = {}
      local cur = {}
      for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        if line == "" then
          if #cur > 0 then
            paragraphs[#paragraphs + 1] = A.paragraph(parse_inline(table.concat(cur, "\n")))
            cur = {}
          end
        else
          cur[#cur + 1] = line
        end
      end
      if #cur > 0 then
        paragraphs[#paragraphs + 1] = A.paragraph(parse_inline(table.concat(cur, "\n")))
      end
      return A.block("quote", { content = paragraphs })
    end
    -- Unknown / custom greater_block: keep body opaque, style = name.
    return A.block(name, { body = block_body(node, src) })
  elseif t == "example_block" then
    return A.block("example", { body = block_body(node, src) })
  elseif t == "verse_block" then
    return A.block("verse", { body = block_body(node, src) })
  elseif t == "export_block" then
    local backend
    for c in node:iter_children() do
      if c:type() == "src_block_language" then
        backend = get_text(c, src)
      end
    end
    return A.block("export", { body = block_body(node, src), backend = backend })
  elseif t == "table" then
    return parse_table(node, src)
  elseif t == "footnote_definition" then
    -- The grammar's `footnote_definition` node spans from `[fn:LABEL]`
    -- to the next blank line / next definition / next headline.  Read
    -- the source text, strip the leading `[fn:LABEL]` token, and parse
    -- the remainder as a paragraph.
    local sr, _, er, ec = node:range()
    local last_row = ec > 0 and er or er - 1
    local pieces = {}
    for r = sr, last_row do
      pieces[#pieces + 1] = src[r + 1] or ""
    end
    local raw = table.concat(pieces, "\n")
    local label, body = raw:match("^%s*%[fn:([^%]:]+)%]%s*(.*)$")
    if not label then
      return nil
    end
    -- Body may span multiple lines; treat as one paragraph for now.
    return A.footnote_definition(label, { A.paragraph(parse_inline(body)) })
  elseif t == "drawer" then
    -- A generic drawer (:LOGBOOK:, custom). Its `drawer_name` child is
    -- the bare name; the LAST `:` child sits on the :END: line. Body is
    -- the verbatim lines strictly between the opener and :END:.
    local name, end_row
    for c in node:iter_children() do
      local ct = c:type()
      if ct == "drawer_name" then
        name = get_text(c, src)
      elseif ct == ":" then
        end_row = c:start()
      end
    end
    if not name or not end_row then
      return nil
    end
    local open_row = node:start()
    local body_lines = {}
    for r = open_row + 1, end_row - 1 do
      body_lines[#body_lines + 1] = src[r + 1] or ""
    end
    return A.drawer(name, table.concat(body_lines, "\n"))
  elseif t == "comment" then
    -- One or more `# ...` lines grouped under a `comment` node. Each
    -- comment_line's comment_body is the text after `#` (leading space
    -- included); preserve it verbatim, joined with newlines.
    local bodies = {}
    for c in node:iter_children() do
      if c:type() == "comment_line" then
        local cb
        for cc in c:iter_children() do
          if cc:type() == "comment_body" then
            cb = get_text(cc, src)
          end
        end
        bodies[#bodies + 1] = cb or ""
      end
    end
    return A.comment(table.concat(bodies, "\n"))
  elseif t == "comment_block" then
    return A.block("comment", { body = block_body(node, src) })
  end
  return nil
end

-- Public entry: parse a buffer (passed as a bufnr or as a list of
-- source lines) and return a `document` AST.
function M.from_lines(src)
  -- Trailing newline so the grammar terminates the final line; without it
  -- a construct on the last line (a directive, a #+TBLFM, a table row)
  -- parses as an ERROR node and is dropped.
  local ok, parser = pcall(vim.treesitter.get_string_parser, table.concat(src, "\n") .. "\n", "org")
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
      local body = emit_section_children(c, src)
      for _, b in ipairs(body) do
        doc_children[#doc_children + 1] = b
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
