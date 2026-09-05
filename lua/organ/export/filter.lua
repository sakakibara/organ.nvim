-- Export-time pruning of a document AST, following ox.el's
-- `org-export--prune-tree` and `org-export--remove-uninterpreted-data`.
--
-- Two passes over the tree:
--
--   1. Prune.  Drop what must never reach a backend: subtrees carrying an
--      exclude tag, everything outside a select-tagged tree when one
--      exists, COMMENT subtrees, comments, `:exports none` source blocks
--      and their results, plus whatever the `#+OPTIONS:` toggles switch
--      off at the tree level.
--   2. Rewrite.  Objects the options say not to interpret (entities,
--      emphasis, sub/superscripts, LaTeX) turn back into the org text
--      they were written as.
--
-- Options the backends apply themselves -- numbering, table of contents,
-- title/author/date blocks, smart quotes, special strings, line-break
-- preservation, tag/TODO/priority rendering -- are left alone here and
-- read from `doc.options`.

local A = require("organ.ast")

local M = {}

local function set_of(list)
  local s = {}
  for _, v in ipairs(list or {}) do
    s[v] = true
  end
  return s
end

local function any_in(list, set)
  for _, v in ipairs(list or {}) do
    if set[v] then
      return true
    end
  end
  return false
end

local function each_headline(node, fn)
  for _, c in ipairs(node.children or {}) do
    if c.kind == "headline" then
      fn(c)
      each_headline(c, fn)
    end
  end
end

-- org-export--selected-trees: the set of headlines belonging to a tree
-- that carries a select tag, together with their ancestors.  Returns nil
-- when no select tag is present, meaning "no selection is in force".
local function selected_trees(doc, select_set, filetags)
  local sel, found = {}, false
  if any_in(filetags, select_set) then
    each_headline(doc, function(h)
      sel[h], found = true, true
    end)
    return found and sel or nil
  end
  local function mark_subtree(h)
    sel[h] = true
    each_headline(h, function(d)
      sel[d] = true
    end)
  end
  local function walk(node, genealogy)
    for _, c in ipairs(node.children or {}) do
      if c.kind == "headline" then
        if any_in(c.tags, select_set) then
          found = true
          for _, g in ipairs(genealogy) do
            sel[g] = true
          end
          mark_subtree(c)
        else
          genealogy[#genealogy + 1] = c
          walk(c, genealogy)
          genealogy[#genealogy] = nil
        end
      end
    end
  end
  walk(doc, {})
  return found and sel or nil
end

local function drawer_kept(name, with_drawers)
  if with_drawers == true then
    return true
  elseif not with_drawers then
    return false
  end
  local lower = (name or ""):lower()
  local list = with_drawers["not"] or with_drawers
  local listed = false
  for _, n in ipairs(list) do
    if n:lower() == lower then
      listed = true
      break
    end
  end
  if with_drawers["not"] then
    return not listed
  end
  return listed
end

-- `:exports` babel header argument of a source block: code | results |
-- both | none.  Emacs's default comes from org-babel-default-header-args.
local function exports_of(code_block)
  return (code_block.params or ""):match(":exports%s+(%a+)") or "code"
end

local function is_results(block)
  for _, kw in ipairs(block.affiliated or {}) do
    if kw.name == "RESULTS" then
      return true
    end
  end
  return false
end

-- Inline pruning: drop objects the options switch off, and turn the
-- uninterpreted ones back into plain text.
local function prune_inline(nodes, o)
  local out = {}
  local function push_text(s)
    local prev = out[#out]
    if prev and prev.kind == "text" then
      prev.text = prev.text .. s
    else
      out[#out + 1] = A.text(s)
    end
  end
  local function splice(open, content, close)
    push_text(open)
    for _, c in ipairs(prune_inline(content, o)) do
      if c.kind == "text" then
        push_text(c.text)
      else
        out[#out + 1] = c
      end
    end
    push_text(close)
  end
  for _, n in ipairs(nodes or {}) do
    local k = n.kind
    if k == "footnote_ref" and not o.with_footnotes then
      -- dropped
    elseif k == "statistics_cookie" and not o.with_statistics_cookies then
      -- dropped
    elseif k == "entity" and not o.with_entities then
      push_text("\\" .. (n.name or ""))
    elseif
      k == "emphasis"
      and not o.with_emphasize
      and (
        n.style == "bold"
        or n.style == "italic"
        or n.style == "underline"
        or n.style == "strike"
      )
    then
      local delim = ({ bold = "*", italic = "/", underline = "_", strike = "+" })[n.style]
      splice(delim, n.content, delim)
    elseif (k == "subscript" or k == "superscript") and o.with_sub_superscript ~= true then
      if o.with_sub_superscript == "{}" and n.brackets then
        n.content = prune_inline(n.content, o)
        out[#out + 1] = n
      else
        local mark = k == "subscript" and "_" or "^"
        splice(mark .. (n.brackets and "{" or ""), n.content, n.brackets and "}" or "")
      end
    elseif k == "math" and o.with_latex ~= true then
      if o.with_latex == "verbatim" then
        local style = n.style or "dollar"
        local open = style == "paren" and "\\("
          or style == "bracket" and "\\["
          or (n.display and "$$" or "$")
        local close = style == "paren" and "\\)"
          or style == "bracket" and "\\]"
          or (n.display and "$$" or "$")
        push_text(open .. (n.body or "") .. close)
      end
    elseif k == "text" then
      push_text(n.text or "")
    else
      for _, slot in ipairs({ "content", "description" }) do
        if n[slot] then
          n[slot] = prune_inline(n[slot], o)
        end
      end
      out[#out + 1] = n
    end
  end
  return out
end

-- A paragraph made only of timestamps and whitespace is what
-- `:with-timestamps` governs; timestamps anywhere else always stay.
local function is_isolated_timestamp_paragraph(block)
  local seen = false
  for _, n in ipairs(block.inline or {}) do
    if n.kind == "timestamp" then
      seen = true
    elseif not (n.kind == "text" and n.text:match("^%s*$")) then
      return false
    end
  end
  return seen
end

local function skip_timestamp(with, variant)
  if with == true then
    return false
  elseif not with then
    return true
  elseif with == "active" then
    return variant ~= "active" and variant ~= "range_active"
  elseif with == "inactive" then
    return variant ~= "inactive" and variant ~= "range_inactive"
  end
  return false
end

local prune_blocks

local function prune_headline(h, o, selected, excluded)
  local tags = h._inherited_tags or h.tags or {}
  if any_in(tags, excluded) then
    return nil
  end
  if selected and not selected[h] then
    return nil
  end
  if h.commented then
    return nil
  end
  local archived = false
  for _, t in ipairs(tags) do
    if t == "ARCHIVE" then
      archived = true
    end
  end
  if archived and not o.with_archived_trees then
    return nil
  end
  if h.todo then
    local w = o.with_tasks
    if not w then
      return nil
    elseif w == "todo" or w == "done" then
      if h.todo_type ~= w then
        return nil
      end
    elseif type(w) == "table" then
      local found = false
      for _, kw in ipairs(w) do
        if kw == h.todo then
          found = true
        end
      end
      if not found then
        return nil
      end
    end
  end
  -- `planning` and `properties` stay on the node: in ox.el they are
  -- headline properties, and `:with-planning` / `:with-properties` only
  -- govern whether a backend prints the planning line and the drawer.
  -- ox-icalendar reads the same properties with those options off.
  h.title = prune_inline(h.title, o)
  if archived and o.with_archived_trees == "headline" then
    h.children = {}
  else
    h.children = prune_blocks(h.children, o, selected, excluded)
  end
  h._inherited_tags = nil
  return h
end

prune_blocks = function(blocks, o, selected, excluded)
  local out = {}
  local drop_next_results = false
  for _, b in ipairs(blocks or {}) do
    local keep = true
    local k = b.kind
    if drop_next_results and k ~= "code_block" and is_results(b) then
      keep = false
      drop_next_results = false
    elseif k == "headline" then
      b = prune_headline(b, o, selected, excluded)
      keep = b ~= nil
      drop_next_results = false
    elseif k == "comment" or (k == "block" and b.style == "comment") then
      keep = false
    elseif k == "drawer" then
      keep = drawer_kept(b.name, o.with_drawers)
    elseif k == "fixed_width" then
      keep = o.with_fixed_width and true or false
      drop_next_results = false
    elseif k == "table" then
      keep = o.with_tables and true or false
      if keep then
        for _, row in ipairs(b.rows or {}) do
          for i, cell in ipairs(row.cells or {}) do
            row.cells[i] = prune_inline(cell, o)
          end
        end
      end
      drop_next_results = false
    elseif k == "latex_environment" then
      -- tex:nil removes it; tex:verbatim keeps it for the backend to
      -- render as literal text rather than pass through.
      keep = o.with_latex and true or false
      drop_next_results = false
    elseif k == "footnote_definition" then
      keep = o.with_footnotes and true or false
      if keep then
        b.content = prune_blocks(b.content, o, selected, excluded)
      end
      drop_next_results = false
    elseif k == "code_block" then
      local exports = exports_of(b)
      keep = exports == "code" or exports == "both"
      drop_next_results = exports == "code" or exports == "none"
    elseif k == "paragraph" then
      if is_isolated_timestamp_paragraph(b) then
        local kept = {}
        for _, n in ipairs(b.inline) do
          if not (n.kind == "timestamp" and skip_timestamp(o.with_timestamps, n.variant)) then
            kept[#kept + 1] = n
          end
        end
        b.inline = kept
        keep = #kept > 0
      end
      if keep then
        b.inline = prune_inline(b.inline, o)
      end
      drop_next_results = false
    elseif k == "list" then
      for _, item in ipairs(b.items or {}) do
        if item.tag then
          item.tag = prune_inline(item.tag, o)
        end
        item.content = prune_blocks(item.content, o, selected, excluded)
      end
      drop_next_results = false
    elseif k == "block" then
      if b.content then
        b.content = prune_blocks(b.content, o, selected, excluded)
      end
      drop_next_results = false
    else
      drop_next_results = false
    end
    if keep and b then
      for _, kw in ipairs(b.affiliated or {}) do
        if kw.inline then
          kw.inline = prune_inline(kw.inline, o)
        end
      end
      out[#out + 1] = b
    end
  end
  return out
end

-- Record each headline's inherited tag list (own + ancestors + FILETAGS),
-- which is what org-export-get-tags builds for the exclude-tag test.
local function annotate_tags(node, inherited)
  for _, c in ipairs(node.children or {}) do
    if c.kind == "headline" then
      local tags = vim.list_extend(vim.list_extend({}, inherited), c.tags or {})
      c._inherited_tags = tags
      annotate_tags(c, tags)
    end
  end
end

-- `substitute-env-in-file-name`: `$NAME` / `${NAME}` become the
-- environment variable's value, `$$` a literal `$`.  A name with no
-- value in the environment is left exactly as written.
local function substitute_env(path)
  if not path:find("$", 1, true) then
    return path
  end
  local out, i = {}, 1
  while true do
    local s = path:find("$", i, true)
    if not s then
      out[#out + 1] = path:sub(i)
      break
    end
    out[#out + 1] = path:sub(i, s - 1)
    local rest = path:sub(s + 1)
    if rest:sub(1, 1) == "$" then
      out[#out + 1] = "$"
      i = s + 2
    else
      local braced = rest:match("^{([^{}]+)}")
      local name = braced or rest:match("^[%w_]+")
      local width = braced and (#braced + 3) or (name and #name + 1)
      if not name then
        out[#out + 1] = "$"
        i = s + 1
      else
        local value = vim.env[name]
        out[#out + 1] = value or path:sub(s, s + width - 1)
        i = s + width
      end
    end
  end
  return table.concat(out)
end

-- Only a file link's path is expanded, and only the path: a `::search`
-- suffix and every other link type pass through untouched.
local function expand_target(target)
  if type(target) ~= "string" then
    return target
  end
  local scheme, rest = target:match("^(%a[%w+.-]*):(.*)$")
  local prefix = ""
  if scheme then
    if scheme ~= "file" then
      return target
    end
    prefix, target = "file:", rest
  elseif not (target:match("^%.?%.?/") or target:sub(1, 1) == "~") then
    return target
  end
  local path, search = target:match("^(.-)::(.*)$")
  if path then
    return prefix .. substitute_env(path) .. "::" .. search
  end
  return prefix .. substitute_env(target)
end

-- ox.el `org-export--expand-links`.
local function expand_links(doc)
  local function expand(n)
    if n.kind == "link" or n.kind == "image" then
      n.target = expand_target(n.target)
    end
  end
  A.walk(doc, function(n)
    expand(n)
    for _, a in ipairs(n.affiliated or {}) do
      for _, c in ipairs(a.inline or {}) do
        A.walk(c, expand)
      end
    end
  end)
end

-- Prune `doc` for export.  `overrides` (optional) wins over the
-- document's own `#+OPTIONS:`.  Mutates and returns the document.
function M.apply(doc, overrides)
  local options = require("organ.export.options")
  local o = doc.options or options.defaults()
  if overrides and next(overrides) then
    o = vim.tbl_extend("force", o, overrides)
  end
  doc.options = o

  local excluded = set_of(o.exclude_tags)
  local selected = selected_trees(doc, set_of(o.select_tags), o.filetags)
  annotate_tags(doc, o.filetags or {})

  local children = doc.children or {}
  if selected then
    -- ox.el drops the section before the first headline when a select
    -- tag is in force.
    local first = {}
    for _, c in ipairs(children) do
      if c.kind == "headline" then
        first[#first + 1] = c
      end
    end
    children = first
  end
  doc.children = prune_blocks(children, o, selected, excluded)
  if o.expand_links then
    expand_links(doc)
  end
  return doc
end

return M
