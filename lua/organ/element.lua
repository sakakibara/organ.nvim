-- Shared element-at-cursor / element-extraction layer.
--
-- Wraps the org + org_inline tree-sitter grammars so callers (lsp,
-- hover, refactor, action_menu, complete/*) don't each re-implement
-- headline / drawer / src_block / link detection.
--
-- ── How the two grammars compose ─────────────────────────────────────
-- Block grammar (`org`) — headlines, sections, drawers, blocks,
-- lists, tables, paragraphs, directives. The heading line itself
-- decomposes into named children:
--
--   (headline
--     (headline_line
--       stars: (stars)
--       todo: (todo)?
--       priority: (priority)?
--       title: (title)?
--       tag_list: (tag_list (tag) (tag) ...)?)
--     (section ...)?
--     (headline ...)*)
--
-- Inline grammar (`org_inline`) — injected into paragraph/headline_line/
-- list_item/table_row content. Exposes link_regular/plain/angle/radio
-- nodes; link_regular has `target` and optional `description` fields:
--
--   (link_regular
--     target: (link_target)
--     description: (link_description)?)
--
-- Inline injection is gated by `queries/org/injections.scm` so it does
-- NOT fire inside src_block / example_block / verse_block / export_block /
-- comment_block. That gives us the "inert region" check for free —
-- callers see no link nodes inside those blocks.

local M = {}

local NODE_KIND = {
  -- block grammar (sakakibara/tree-sitter-organ)
  document = "document",
  zeroth_section = "zeroth_section",
  headline = "headline",
  headline_line = "headline_line",
  stars = "stars",
  todo = "todo",
  priority = "priority",
  title = "title",
  tag_list = "tag_list",
  tag = "tag",
  section = "section",
  property_drawer = "property_drawer",
  node_property = "node_property",
  drawer = "drawer",
  greater_block = "block",
  dynamic_block = "block",
  src_block = "src_block",
  example_block = "example_block",
  export_block = "export_block",
  verse_block = "verse_block",
  comment_block = "comment_block",
  latex_environment = "latex_environment",
  list = "list",
  list_item = "list_item",
  table = "table",
  table_row = "table_row",
  table_cell = "table_cell",
  table_rule = "table_rule",
  footnote_definition = "footnote_definition",
  inlinetask = "inlinetask",
  clock = "clock",
  keyword = "keyword",
  affiliated_keyword = "affiliated_keyword",
  comment = "comment",
  fixed_width = "fixed_width",
  horizontal_rule = "horizontal_rule",
  diary_sexp = "diary_sexp",
  paragraph = "paragraph",
  planning = "planning",

  -- inline grammar (sakakibara/tree-sitter-organ-inline). Sub-components
  -- of link_regular (link_target / link_description) are intentionally
  -- NOT mapped — `M.at()` walks up to the enclosing `link` instead.
  link_regular = "link",
  link_plain = "link",
  link_angle = "link",
  link_radio = "link",
  bold = "emphasis",
  italic = "emphasis",
  underline = "emphasis",
  strike = "emphasis",
  code = "verbatim",
  verbatim = "verbatim",
  timestamp_active = "timestamp",
  timestamp_inactive = "timestamp",
  timestamp_range_active = "timestamp",
  timestamp_range_inactive = "timestamp",
  citation = "citation",
  macro = "macro",
  inline_src_block = "inline_src_block",
  footnote_ref = "footnote_ref",
  statistics_cookie = "statistics_cookie",
  latex_fragment = "latex_fragment",
  entity = "entity",
  target = "target",
}

-- src_block / example_block / etc. — inline content is not injected
-- into these by `queries/org/injections.scm`, so callers automatically
-- see no link nodes inside them.
local INERT_BLOCK_TYPES = {
  src_block = true,
  example_block = true,
  verse_block = true,
  export_block = true,
  comment_block = true,
  latex_environment = true,
}

local _parser_status = {}

function M.parser_loaded(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cached = _parser_status[bufnr]
  if cached ~= nil then
    return cached
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  local available = ok and parser ~= nil
  _parser_status[bufnr] = available
  return available
end

function M.invalidate(bufnr)
  if bufnr then
    _parser_status[bufnr] = nil
  else
    _parser_status = {}
  end
end

-- The multi-language LanguageTree for `bufnr`. Calls parse(true) to
-- force recursive parsing of injected sub-grammars (org_inline) so
-- callers can reach inline trees via for_each_tree.
function M.lang_tree(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not M.parser_loaded(bufnr) then
    return nil
  end
  local parser = vim.treesitter.get_parser(bufnr, "org")
  if not parser then
    return nil
  end
  parser:parse(true)
  return parser
end

-- Root node of the BLOCK (org) grammar.
function M.root(bufnr)
  local lt = M.lang_tree(bufnr)
  if not lt then
    return nil
  end
  local trees = lt:trees()
  return trees and trees[1] and trees[1]:root() or nil
end

-- ── helpers ──────────────────────────────────────────────────────────

local function node_text(node, bufnr)
  if not node then
    return ""
  end
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  return ok and text or ""
end

local function field_first(node, name)
  if not node then
    return nil
  end
  local matches = node:field(name)
  return matches and matches[1] or nil
end

-- True when (row, col) sits inside an inert block.
function M.in_inert_block(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not M.parser_loaded(bufnr) then
    return false
  end
  local root = M.root(bufnr)
  if not root then
    return false
  end
  local node = root:descendant_for_range(row, col, row, col)
  while node do
    if INERT_BLOCK_TYPES[node:type()] then
      return true
    end
    node = node:parent()
  end
  return false
end

-- ── public API ───────────────────────────────────────────────────────

-- Element kind at (row, col). Walks across BOTH grammars (block + inline)
-- so a cursor on `[[...]]` returns the inline `link` kind (not the
-- enclosing `paragraph`).
function M.at(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local lt = M.lang_tree(bufnr)
    if lt then
      local found_inline, found_block = nil, nil
      lt:for_each_tree(function(tree, langtree)
        local lang = langtree:lang()
        if lang ~= "org" and lang ~= "org_inline" then
          return
        end
        local root = tree:root()
        local sr, _, er = root:range()
        if row < sr or row > er then
          return
        end
        local node = root:descendant_for_range(row, col, row, col)
        while node do
          local kind = NODE_KIND[node:type()]
          if kind then
            local nsr, nsc, ner, nec = node:range()
            local hit = {
              kind = kind,
              node = node,
              range = { nsr, nsc, ner, nec },
              text = node_text(node, bufnr),
              lang = lang,
              type = node:type(),
            }
            if lang == "org_inline" then
              found_inline = hit
            else
              found_block = hit
            end
            return
          end
          node = node:parent()
        end
      end)
      return found_inline or found_block
    end
  end
  -- Regex fallback: just enough to keep callers functional when
  -- treesitter isn't available.
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  if line:match("^%*+%s") then
    return { kind = "headline", range = { row, 0, row, #line } }
  end
  if line:match("^%s*[-+*]%s") or line:match("^%s*%d+[%.)]%s") then
    return { kind = "list_item", range = { row, 0, row, #line } }
  end
  if line:match("^%s*:[%w_]+:%s*$") then
    return { kind = "drawer", range = { row, 0, row, #line } }
  end
  if line:match("^%s*#%+") then
    return { kind = "directive", range = { row, 0, row, #line } }
  end
  return { kind = "paragraph", range = { row, 0, row, #line } }
end

-- ── headlines ────────────────────────────────────────────────────────

-- Regex fallback for headline parsing when tree-sitter is unavailable
-- or finds no headline.
local function headline_info_from_line(line, row0)
  local level, rest = require("organ.headline").split(line)
  if not level then
    return nil
  end
  local seq = require("organ.buf_config").read(nil, "todo.sequence") or {}
  local todo = nil
  for _, kw in ipairs(seq) do
    if kw ~= "|" and rest:sub(1, #kw + 1) == kw .. " " then
      todo = kw
      rest = rest:sub(#kw + 2)
      break
    end
  end
  local pri = rest:match("^(%[#[A-Z0-9]%])%s+")
  local priority
  if pri then
    priority = pri:sub(3, 3)
    rest = rest:sub(#pri + 2)
  end
  local tags = {}
  local tag_block = rest:match("%s+:([%w_@#%%:%-]+):%s*$")
  if tag_block then
    rest = rest:gsub("%s+:[%w_@#%%:%-]+:%s*$", "")
    for t in tag_block:gmatch("[^:]+") do
      tags[#tags + 1] = t
    end
  end
  return {
    range = { row0, 0, row0, #line },
    line_start = row0,
    line_end = row0,
    level = level,
    todo_state = todo,
    priority = priority,
    title = rest,
    tags = tags,
  }
end

-- Walk a TS node and pull out the `headline_line` info — stars, todo,
-- priority, title, tags. Returns the parsed table or nil if the node
-- isn't a headline / headline_line.
local function parse_headline_node(headline_node, bufnr)
  local sr, sc, er, ec = headline_node:range()
  local hl_line = nil
  for c in headline_node:iter_children() do
    if c:type() == "headline_line" then
      hl_line = c
      break
    end
  end
  if not hl_line then
    return nil
  end
  local stars_n = field_first(hl_line, "stars")
  local todo_n = field_first(hl_line, "todo")
  local prio_n = field_first(hl_line, "priority")
  local title_n = field_first(hl_line, "title")
  local tag_list_n = field_first(hl_line, "tag_list")
  local stars_text = node_text(stars_n, bufnr)
  local tags = {}
  if tag_list_n then
    for c in tag_list_n:iter_children() do
      if c:type() == "tag" then
        tags[#tags + 1] = node_text(c, bufnr)
      end
    end
  end
  local title = node_text(title_n, bufnr):gsub("%s+$", "")
  return {
    node = headline_node,
    range = { sr, sc, er, ec },
    line_start = sr,
    level = #stars_text,
    todo_state = todo_n and node_text(todo_n, bufnr) or nil,
    priority = prio_n and node_text(prio_n, bufnr):match("%[#(.)]") or nil,
    title = title,
    tags = tags,
  }
end

-- The headline enclosing `row`, plus parsed metadata: a record with
-- line_start / line_end / level / todo_state / priority / title / tags.
-- The `node` field is the live tree-sitter headline node, present only
-- when the parser is loaded; it is absent on the regex fallback, so
-- callers that traverse it must guard for nil.
function M.headline_at(bufnr, row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local root = M.root(bufnr)
    if root then
      local node = root:descendant_for_range(row, 0, row, 0)
      while node do
        if node:type() == "headline" then
          local info = parse_headline_node(node, bufnr)
          if info then
            info.line_end = (select(3, node:range())) - 1
            return info
          end
        end
        node = node:parent()
      end
    end
  end
  -- Regex fallback.
  for r = row, 0, -1 do
    local ln = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] or ""
    if ln:match("^%*+%s") then
      return headline_info_from_line(ln, r)
    end
  end
  return nil
end

-- All headlines, in source order.
function M.headlines(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local out = {}
  if M.parser_loaded(bufnr) then
    local root = M.root(bufnr)
    if root then
      local function visit(node)
        if node:type() == "headline" then
          local info = parse_headline_node(node, bufnr)
          if info then
            -- TS headline node range already covers the whole subtree.
            -- end_row is exclusive of the next-headline's first line, so
            -- subtract 1 to make it inclusive.
            local _, _, er = node:range()
            info.line_end = er > info.line_start and (er - 1) or info.line_start
            out[#out + 1] = info
          end
        end
        for c in node:iter_children() do
          visit(c)
        end
      end
      visit(root)
      return out
    end
  end
  -- Regex fallback. line_end = the line BEFORE the next headline at
  -- same OR shallower level (matches subtree boundary semantics).
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      out[#out + 1] = headline_info_from_line(ln, i - 1)
    end
  end
  for i, h in ipairs(out) do
    local end_line = #lines - 1
    for j = i + 1, #out do
      if out[j].level <= h.level then
        end_line = out[j].line_start - 1
        break
      end
    end
    h.line_end = end_line
  end
  return out
end

-- ── links (TS-driven, multi-language tree walk) ──────────────────────

local function iter_inline_links(bufnr, fn)
  local lt = M.lang_tree(bufnr)
  if not lt then
    return
  end
  lt:for_each_tree(function(tree, langtree)
    if langtree:lang() ~= "org_inline" then
      return
    end
    local function visit(n)
      local t = n:type()
      if t == "link_regular" or t == "link_plain" or t == "link_angle" or t == "link_radio" then
        fn(n, bufnr, t)
      end
      for c in n:iter_children() do
        visit(c)
      end
    end
    visit(tree:root())
  end)
end

local function link_info_from_node(node, bufnr, ttype)
  local sr, sc, er, ec = node:range()
  local target
  local desc = ""
  if ttype == "link_regular" then
    local tgt = field_first(node, "target")
    local dsc = field_first(node, "description")
    target = tgt and node_text(tgt, bufnr) or ""
    desc = dsc and node_text(dsc, bufnr) or ""
  else
    target = node_text(node, bufnr)
  end
  return {
    line = sr,
    col_start = sc,
    end_line = er,
    end_col = ec,
    col_end = ec,
    body = node_text(node, bufnr),
    target = target,
    description = desc,
    kind = ttype:gsub("^link_", ""),
    node = node,
  }
end

-- All links in the buffer.
function M.links(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local out = {}
  if M.parser_loaded(bufnr) then
    iter_inline_links(bufnr, function(node, b, ttype)
      out[#out + 1] = link_info_from_node(node, b, ttype)
    end)
    return out
  end
  -- Regex fallback (no TS): scan each line for `[[...]]`.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, ln in ipairs(lines) do
    local search_from = 1
    while true do
      local s, e = ln:find("%[%[.-%]%]", search_from)
      if not s then
        break
      end
      local body = ln:sub(s + 2, e - 2)
      local target = body:gsub("%]%[.*$", "")
      local desc = body:match("%]%[(.*)$") or ""
      out[#out + 1] = {
        line = i - 1,
        col_start = s - 1,
        col_end = e,
        end_line = i - 1,
        end_col = e,
        body = ln:sub(s, e),
        target = target,
        description = desc,
        kind = "regular",
      }
      search_from = e + 1
    end
  end
  return out
end

-- Single link at (row, col), or nil.
function M.link_at(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local hit
    iter_inline_links(bufnr, function(node, b, ttype)
      if hit then
        return
      end
      local sr, sc, er, ec = node:range()
      if row < sr or row > er then
        return
      end
      if row == sr and col < sc then
        return
      end
      if row == er and col > ec then
        return
      end
      hit = link_info_from_node(node, b, ttype)
    end)
    return hit
  end
  -- Regex fallback.
  if M.in_inert_block(bufnr, row, col) then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local search_from = 1
  while true do
    local s, e = line:find("%[%[.-%]%]", search_from)
    if not s then
      return nil
    end
    if col + 1 >= s and col + 1 <= e then
      local body = line:sub(s + 2, e - 2)
      local target = body:gsub("%]%[.*$", "")
      local desc = body:match("%]%[(.*)$") or ""
      return {
        line = row,
        col_start = s - 1,
        col_end = e,
        end_line = row,
        end_col = e,
        body = line:sub(s, e),
        target = target,
        description = desc,
        kind = "regular",
      }
    end
    search_from = e + 1
  end
end

-- ── per-element accessors ───────────────────────────────────────────

-- Inlinetasks under `bufnr`, in source order. Same shape as headlines
-- but for inlinetasks (`*************** ...` with 15+ stars).
function M.inlinetasks(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local out = {}
  if M.parser_loaded(bufnr) then
    local root = M.root(bufnr)
    if root then
      local function visit(node)
        if node:type() == "inlinetask" then
          local sr, sc, er, ec = node:range()
          local hl_line = nil
          for c in node:iter_children() do
            if c:type() == "inlinetask_line" then
              hl_line = c
              break
            end
          end
          if hl_line then
            local todo_n = field_first(hl_line, "todo")
            local prio_n = field_first(hl_line, "priority")
            local title_n = field_first(hl_line, "title")
            local tags_n = field_first(hl_line, "tag_list")
            local tags = {}
            if tags_n then
              for c in tags_n:iter_children() do
                if c:type() == "tag" then
                  tags[#tags + 1] = node_text(c, bufnr)
                end
              end
            end
            out[#out + 1] = {
              node = node,
              range = { sr, sc, er, ec },
              line_start = sr,
              line_end = er > sr and (er - 1) or sr,
              level = 0, -- inlinetasks aren't outline-leveled
              todo_state = todo_n and node_text(todo_n, bufnr) or nil,
              priority = prio_n and node_text(prio_n, bufnr):match("%[#(.)]") or nil,
              title = title_n and node_text(title_n, bufnr):gsub("%s+$", "") or "",
              tags = tags,
              kind = "inlinetask",
            }
          end
        end
        for c in node:iter_children() do
          visit(c)
        end
      end
      visit(root)
    end
  end
  return out
end

-- Checkbox state at `row`, if the cursor row is a list_item with one.
-- Returns one of: "todo" | "done" | "half" | nil.
function M.checkbox_at(bufnr, row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local root = M.root(bufnr)
    if root then
      local node = root:descendant_for_range(row, 0, row, 0)
      while node do
        if node:type() == "list_item" then
          local cb = field_first(node, "checkbox")
          if cb then
            local txt = node_text(cb, bufnr)
            if txt:find("[xX]", 1, true) then
              return "done"
            end
            if txt:find("-", 1, true) then
              return "half"
            end
            return "todo"
          end
          return nil
        end
        node = node:parent()
      end
    end
  end
  -- Regex fallback.
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local box = line:match("^%s*[-+*]%s+(%[.])") or line:match("^%s*%d+[%.)]%s+(%[.])")
  if not box then
    return nil
  end
  if box:find("[xX]", 1, true) then
    return "done"
  end
  if box:find("-", 1, true) then
    return "half"
  end
  return "todo"
end

-- TODO keyword at `row`'s headline, or nil.
function M.todo_at(bufnr, row)
  local h = M.headline_at(bufnr, row)
  return h and h.todo_state or nil
end

-- Tag list at `row`'s headline, or `{}`. Returns flat list of tag strings.
function M.tags_at(bufnr, row)
  local h = M.headline_at(bufnr, row)
  return h and h.tags or {}
end

-- Statistics cookie text at `row`'s headline (e.g. "[33%]" or "[1/3]"),
-- or nil. Useful for "auto-update cookie" features.
function M.statistics_cookie_at(bufnr, row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local h = M.headline_at(bufnr, row)
    if h and h.node then
      for c in h.node:iter_children() do
        if c:type() == "headline_line" then
          local cookie = field_first(c, "cookie")
          if cookie then
            return node_text(cookie, bufnr)
          end
          return nil
        end
      end
    end
  end
  return nil
end

-- Returns `{ start_line = ..., end_line = ... }` (1-based, inclusive of
-- `:PROPERTIES:` and `:END:` lines) for the property drawer attached
-- to the headline that contains row `row` (0-based).  Returns nil
-- when the headline has no property drawer.  TS-first; regex fallback
-- skips planning lines and matches `:PROPERTIES:`/`:END:` directly.
function M.property_drawer_range(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local h = M.headline_at(bufnr, headline_row)
    if h and h.node then
      for child in h.node:iter_children() do
        if child:type() == "section" then
          for c in child:iter_children() do
            if c:type() == "property_drawer" then
              local sr, _, er = c:range()
              -- TS end_row is the row AFTER the closing `:END:` line.
              -- Convert to 1-based inclusive.
              return { start_line = sr + 1, end_line = er }
            end
          end
        end
      end
      return nil
    end
  end
  -- Regex fallback (parser not loaded or row outside any node).
  local total = vim.api.nvim_buf_line_count(bufnr)
  local i = headline_row + 2 -- 1-based first line after headline
  while i <= total do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if
      not (txt:match("^%s*SCHEDULED:") or txt:match("^%s*DEADLINE:") or txt:match("^%s*CLOSED:"))
    then
      break
    end
    i = i + 1
  end
  if i > total then
    return nil
  end
  local first = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
  if not first:match("^%s*:PROPERTIES:%s*$") then
    return nil
  end
  local start_line = i
  i = i + 1
  while i <= total do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if txt:match("^%s*:END:%s*$") then
      return { start_line = start_line, end_line = i }
    end
    i = i + 1
  end
  return nil
end

-- 1-based first line where any drawer / body content would begin —
-- i.e., one past the last planning line (SCHEDULED / DEADLINE / CLOSED)
-- after the headline at `headline_row` (0-based).  TS-first via the
-- `planning` node's end row; regex fallback walks planning lines.
function M.planning_end_line(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local h = M.headline_at(bufnr, headline_row)
    if h and h.node then
      for child in h.node:iter_children() do
        if child:type() == "section" then
          for c in child:iter_children() do
            if c:type() == "planning" then
              local _, _, er = c:range()
              return er + 1 -- TS er is exclusive; +1 → 1-based next line
            end
          end
          -- No planning under section.
          local _, _, _ = child:range()
          return headline_row + 2 -- right after headline
        end
      end
      return headline_row + 2
    end
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  local i = headline_row + 2
  while i <= total do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if
      not (txt:match("^%s*SCHEDULED:") or txt:match("^%s*DEADLINE:") or txt:match("^%s*CLOSED:"))
    then
      break
    end
    i = i + 1
  end
  return i
end

-- Returns 1-based line numbers of SCHEDULED / DEADLINE / CLOSED
-- planning entries under the headline at `headline_row` (0-based) as
-- `{ scheduled = N|nil, deadline = N|nil, closed = N|nil }`.  When a
-- single line carries multiple keywords each entry shares that line.
function M.planning_lines(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local out = {}
  if M.parser_loaded(bufnr) then
    local h = M.headline_at(bufnr, headline_row)
    if h and h.node then
      for child in h.node:iter_children() do
        if child:type() == "section" then
          for c in child:iter_children() do
            if c:type() == "planning" then
              local function walk_entries(n)
                if n:type() == "planning_entry" then
                  local kn = field_first(n, "keyword")
                  if kn then
                    local kw = node_text(kn, bufnr):upper()
                    local row = (n:range())
                    if kw == "SCHEDULED" then
                      out.scheduled = row + 1
                    elseif kw == "DEADLINE" then
                      out.deadline = row + 1
                    elseif kw == "CLOSED" then
                      out.closed = row + 1
                    end
                  end
                end
                for cc in n:iter_children() do
                  walk_entries(cc)
                end
              end
              walk_entries(c)
              return out
            end
          end
          return out
        end
      end
      return out
    end
  end
  -- Regex fallback.
  local total = vim.api.nvim_buf_line_count(bufnr)
  local i = headline_row + 2
  while i <= total do
    local ln = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if ln:match("^%*+%s") then
      break
    end
    if ln:match("SCHEDULED:") then
      out.scheduled = i
    end
    if ln:match("DEADLINE:") then
      out.deadline = i
    end
    if ln:match("CLOSED:") then
      out.closed = i
    end
    if
      ln:match("^%s*SCHEDULED:")
      or ln:match("^%s*DEADLINE:")
      or ln:match("^%s*CLOSED:")
      or ln:match("^%s*$")
    then
      i = i + 1
    elseif ln:match("^%s*:[%w_%-]+:%s*$") then
      -- Skip a drawer (e.g. :PROPERTIES:) so planning placed after it
      -- (org-habit layout) is still found, matching the tree-sitter path.
      i = i + 1
      local hit_headline = false
      while i <= total do
        local d = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
        if d:match("^%*+%s") then
          hit_headline = true
          break
        end
        if d:match("^%s*:[Ee][Nn][Dd]:%s*$") then
          break
        end
        i = i + 1
      end
      if hit_headline then
        -- Unterminated drawer ran into the next headline: the section
        -- ends here; never read planning from a sibling headline.
        break
      end
      i = i + 1 -- past :END:
    else
      break
    end
  end
  return out
end

-- Returns the `node_property` key→value map for the property drawer
-- attached to the headline at `headline_row` (0-based), or `{}` when
-- absent.  TS field walks; regex fallback when parser not loaded.
function M.properties_under(bufnr, headline_row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local h = M.headline_at(bufnr, headline_row)
    if h and h.node then
      for child in h.node:iter_children() do
        if child:type() == "section" then
          for c in child:iter_children() do
            if c:type() == "property_drawer" then
              local out = {}
              for np in c:iter_children() do
                if np:type() == "node_property" then
                  local kn = field_first(np, "name")
                  local vn = field_first(np, "value")
                  if kn then
                    local k = node_text(kn, bufnr)
                    local v = vn and node_text(vn, bufnr):gsub("%s+$", "") or ""
                    out[k] = v
                  end
                end
              end
              return out
            end
          end
          return {}
        end
      end
      return {}
    end
  end
  -- Regex fallback.
  local pd = M.property_drawer_range(bufnr, headline_row)
  if not pd then
    return {}
  end
  local out = {}
  for i = pd.start_line + 1, pd.end_line - 1 do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    local k, v = txt:match("^%s*:([%w_]+):%s*(.-)%s*$")
    if k then
      out[k] = v
    end
  end
  return out
end

-- Read property value for `key` at `headline_row` (0-based), with
-- ancestor inheritance: walks up parent headlines, returns the first
-- match.  Returns nil when no ancestor sets the property.
function M.property_value_inherited(bufnr, headline_row, key)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local h = M.headline_at(bufnr, headline_row)
    while h and h.node do
      local props = M.properties_under(bufnr, h.line_start)
      if props[key] and props[key] ~= "" then
        return props[key]
      end
      -- Walk to parent headline (one above with smaller level).
      local p = h.node:parent()
      while p and p:type() ~= "headline" do
        p = p:parent()
      end
      if not p then
        break
      end
      h = M.headline_at(bufnr, (p:range()))
    end
    return nil
  end
  -- Regex fallback: linear walk up the buffer.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cur_lvl = math.huge
  for r = headline_row, 0, -1 do
    local stars = (lines[r + 1] or ""):match("^(%*+)%s")
    if stars and #stars < cur_lvl then
      cur_lvl = #stars
      local pd = M.property_drawer_range(bufnr, r)
      if pd then
        for i = pd.start_line + 1, pd.end_line - 1 do
          local k, v = (lines[i] or ""):match("^%s*:([%w_]+):%s*(.-)%s*$")
          if k == key and v and v ~= "" then
            return v
          end
        end
      end
      if cur_lvl == 1 then
        break
      end
    end
  end
  return nil
end

-- Returns the formula value text on `row` if that line is a `#+TBLFM:`
-- (parsed as a `formula` node), else nil.  The grammar's `formula`
-- decomposition gives us name + value as field accessors; we only
-- expose the value here since callers always want the expression.
function M.formula_at(bufnr, row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local root = M.root(bufnr)
    if root then
      local node = root:descendant_for_range(row, 0, row, 0)
      while node do
        if node:type() == "formula" then
          local v = field_first(node, "value")
          return v and node_text(v, bufnr) or ""
        end
        node = node:parent()
      end
    end
  end
  -- Regex fallback (parser not yet loaded, or row outside any node).
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return (line:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*(.*)$"))
end

-- ── completion-context helpers ───────────────────────────────────────

-- True when (row, col) is in the first-word slot of a headline (where
-- TODO keywords belong). Returns (true, partial) or (false).
-- Pure regex — `descendant_for_range` returns nodes outside the
-- headline_line at end-of-line positions (which is exactly where
-- completion fires), so the regex form is more reliable here.
function M.in_headline_first_word(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local stars = line:match("^(%*+) ")
  if not stars then
    return false
  end
  local first_word_start = #stars + 1
  if col < first_word_start then
    return false
  end
  local before = line:sub(1, col)
  local first_word = before:sub(first_word_start + 1)
  if first_word:find("%s") then
    return false
  end
  return true, first_word
end

-- True when (row, col) is inside a headline's tag_list region.
function M.in_tag_region(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local root = M.root(bufnr)
    if root then
      local node = root:descendant_for_range(row, col, row, col)
      while node do
        if node:type() == "tag_list" then
          return true
        end
        node = node:parent()
      end
    end
  end
  -- Regex fallback.
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  if not line:match("^%*+%s") then
    return false
  end
  local before = line:sub(1, col)
  if not before:match("%s+:[%w_@#%%:%-]*$") then
    return false
  end
  return true
end

-- True when cursor is on a `#+KEYWORD` line.
function M.on_directive(bufnr, row)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if M.parser_loaded(bufnr) then
    local root = M.root(bufnr)
    if root then
      local node = root:descendant_for_range(row, 0, row, 0)
      while node do
        if node:type() == "keyword" or node:type() == "affiliated_keyword" then
          return true
        end
        node = node:parent()
      end
    end
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return line:match("^%s*#%+") ~= nil
end

return M
