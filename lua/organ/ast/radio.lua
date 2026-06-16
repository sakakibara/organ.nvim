local A = require("organ.ast.init")

local M = {}

-- Recursively visit every node, calling fn(node). Covers all child slots
-- that can hold AST nodes, including list items and table cells.
local function visit(n, fn)
  if type(n) ~= "table" then
    return
  end
  if n.kind then
    fn(n)
  end
  for _, slot in ipairs({ "children", "content", "inline", "title", "items", "description", "tag" }) do
    if type(n[slot]) == "table" then
      for _, c in ipairs(n[slot]) do
        visit(c, fn)
      end
    end
  end
  if type(n.rows) == "table" then
    for _, row in ipairs(n.rows) do
      if type(row.cells) == "table" then
        for _, cell in ipairs(row.cells) do
          if type(cell) == "table" then
            for _, c in ipairs(cell) do
              visit(c, fn)
            end
          end
        end
      end
    end
  end
end

-- Dedupe (case-insensitive, first wins), drop blank, sort length-desc
-- (alphabetical tiebreak). Shared by collect_targets and the editor cache
-- so highlight/follow and resolve agree on what matches.
function M.normalize_targets(phrases)
  local seen, order = {}, {}
  for _, p in ipairs(phrases or {}) do
    if type(p) == "string" and p:match("%S") then
      local key = p:lower()
      if not seen[key] then
        seen[key] = true
        order[#order + 1] = p
      end
    end
  end
  table.sort(order, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  return order
end

-- Unique radio-target phrases in document order, deduped case-insensitively,
-- sorted by length descending (longest-match preference).
function M.collect_targets(ast)
  local raw = {}
  visit(ast, function(n)
    if n.kind == "radio_target" and n.phrase then
      raw[#raw + 1] = n.phrase
    end
  end)
  return M.normalize_targets(raw)
end

-- A Lua pattern matching the phrase case-insensitively (caller lowercases
-- the haystack): magic chars escaped, each whitespace run -> `%s+`.
local function phrase_pattern(phrase)
  local segs = {}
  for seg in phrase:lower():gmatch("%S+") do
    segs[#segs + 1] = (seg:gsub("(%W)", "%%%1"))
  end
  return table.concat(segs, "%s+")
end

local function is_alnum(c)
  return c ~= nil and c:match("[%a%d]") ~= nil
end

-- build_matcher(phrases) -> match(s) -> start, stop, phrase | nil.
-- `phrases` should be longest-first (as collect_targets returns).
function M.build_matcher(phrases)
  local pats = {}
  for _, p in ipairs(phrases) do
    pats[#pats + 1] = { phrase = p, pat = "^" .. phrase_pattern(p) }
  end
  return function(s)
    local lower = s:lower()
    for i = 1, #s do
      for _, e in ipairs(pats) do
        local st, sp = lower:find(e.pat, i)
        if st then
          local before = i > 1 and s:sub(i - 1, i - 1) or nil
          local after = sp < #s and s:sub(sp + 1, sp + 1) or nil
          if not is_alnum(before) and not is_alnum(after) then
            return i, sp, e.phrase
          end
        end
      end
    end
    return nil
  end
end

-- Split a plain string into text + radio-link nodes using the matcher.
local function split_text(s, match)
  local out = {}
  while true do
    local st, sp, phrase = match(s)
    if not st or sp < st then
      if s ~= "" then
        out[#out + 1] = A.text(s)
      end
      return out
    end
    if st > 1 then
      out[#out + 1] = A.text(s:sub(1, st - 1))
    end
    out[#out + 1] = A.link(phrase, { A.text(s:sub(st, sp)) }, "radio")
    s = s:sub(sp + 1)
  end
end

-- Resolve an inline list: split text leaves, recurse into linkifiable
-- containers, leave links / verbatim / radio_target / leaf objects intact.
local function resolve_inline(list, match)
  local out = {}
  for _, n in ipairs(list or {}) do
    if n.kind == "text" then
      for _, x in ipairs(split_text(n.text or "", match)) do
        out[#out + 1] = x
      end
    elseif n.kind == "emphasis" then
      if n.style == "verbatim" or n.style == "code" then
        out[#out + 1] = n
      else
        out[#out + 1] =
          { kind = "emphasis", style = n.style, content = resolve_inline(n.content, match) }
      end
    elseif n.kind == "subscript" or n.kind == "superscript" then
      out[#out + 1] = { kind = n.kind, content = resolve_inline(n.content, match) }
    elseif n.kind == "footnote_ref" then
      out[#out + 1] = {
        kind = "footnote_ref",
        label = n.label,
        content = n.content and resolve_inline(n.content, match) or nil,
      }
    else
      out[#out + 1] = n
    end
  end
  return out
end

-- Resolve a block node: recurse block children, resolve inline-bearing fields.
local function resolve_block(n, match)
  if type(n) ~= "table" or not n.kind then
    return n
  end
  local k = n.kind
  if k == "document" then
    local copy = {}
    for key, v in pairs(n) do
      copy[key] = v
    end
    local children = {}
    for _, c in ipairs(n.children or {}) do
      children[#children + 1] = resolve_block(c, match)
    end
    copy.children = children
    return copy
  elseif k == "paragraph" then
    local copy = {}
    for key, v in pairs(n) do
      copy[key] = v
    end
    copy.inline = resolve_inline(n.inline, match)
    return copy
  elseif k == "headline" then
    local copy = {}
    for key, v in pairs(n) do
      copy[key] = v
    end
    copy.title = resolve_inline(n.title, match)
    local children = {}
    for _, c in ipairs(n.children or {}) do
      children[#children + 1] = resolve_block(c, match)
    end
    copy.children = children
    return copy
  elseif k == "list" then
    local copy = {}
    for key, v in pairs(n) do
      copy[key] = v
    end
    local items = {}
    for _, it in ipairs(n.items or {}) do
      items[#items + 1] = resolve_block(it, match)
    end
    copy.items = items
    return copy
  elseif k == "list_item" then
    local copy = {}
    for key, v in pairs(n) do
      copy[key] = v
    end
    if n.tag then
      copy.tag = resolve_inline(n.tag, match)
    end
    local content = {}
    for _, c in ipairs(n.content or {}) do
      content[#content + 1] = resolve_block(c, match)
    end
    copy.content = content
    return copy
  elseif k == "table" then
    local copy = {}
    for key, v in pairs(n) do
      copy[key] = v
    end
    local rows = {}
    for _, row in ipairs(n.rows or {}) do
      if row.sep then
        rows[#rows + 1] = row
      else
        local cells = {}
        for _, cell in ipairs(row.cells or {}) do
          cells[#cells + 1] = resolve_inline(cell, match)
        end
        rows[#rows + 1] = { cells = cells }
      end
    end
    copy.rows = rows
    return copy
  elseif (k == "block" or k == "footnote_definition") and type(n.content) == "table" then
    local copy = {}
    for key, v in pairs(n) do
      copy[key] = v
    end
    local content = {}
    for _, c in ipairs(n.content) do
      content[#content + 1] = resolve_block(c, match)
    end
    copy.content = content
    return copy
  end
  return n
end

-- resolve(ast): a pure transform; occurrences of any radio-target phrase
-- become radio links. No targets -> the input is returned unchanged.
function M.resolve(ast)
  local targets = M.collect_targets(ast)
  if #targets == 0 then
    return ast
  end
  local match = M.build_matcher(targets)
  return resolve_block(ast, match)
end

return M
