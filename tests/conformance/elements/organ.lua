-- Elements conformance gate: organ side.  Prints organ's parse (the org
-- block tree plus the org_inline trees organ's injection query attaches)
-- in the line format emacs.el prints for org-element; NORMALIZE.md maps
-- each node type to its org-element type.

local root = vim.fn.getcwd()
dofile(root .. "/tests/conformance/_clock.lua").pin()

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local extract = require("organ.indexer.extract")
extract.ensure_languages(nil)

local keywords = {}
for _, seq in ipairs(require("organ.todo").effective_sequences(nil)) do
  for _, k in ipairs(seq) do
    if k ~= "|" then
      keywords[k] = true
    end
  end
end

local GREATER = { quote = "quote-block", center = "center-block" }

local SIMPLE = {
  zeroth_section = "section",
  section = "section",
  property_drawer = "property-drawer",
  example_block = "example-block",
  verse_block = "verse-block",
  comment_block = "comment-block",
  latex_environment = "latex-environment",
  list = "plain-list",
  table_cell = "table-cell",
  comment = "comment",
  fixed_width = "fixed-width",
  horizontal_rule = "horizontal-rule",
  paragraph = "paragraph",
}

local OBJECTS = {
  bold = "bold",
  italic = "italic",
  underline = "underline",
  strike = "strike-through",
  code = "code",
  verbatim = "verbatim",
  entity = "entity",
  latex_fragment = "latex-fragment",
  line_break = "line-break",
  export_snippet = "export-snippet",
  footnote_ref = "footnote-reference",
  inline_babel_call = "inline-babel-call",
  inline_src_block = "inline-src-block",
  link_regular = "link",
  link_plain = "link",
  link_angle = "link",
  link_radio = "radio-target",
  macro = "macro",
  statistics_cookie = "statistics-cookie",
  subscript = "subscript",
  superscript = "superscript",
  target = "target",
  citation = "citation",
  citation_reference = "citation-reference",
}

local TIMESTAMPS = {
  timestamp_active = "active",
  timestamp_inactive = "inactive",
  timestamp_range_active = "active-range",
  timestamp_range_inactive = "inactive-range",
  timestamp_diary = "diary",
}

local LEAVES = {
  code = true,
  verbatim = true,
  entity = true,
  latex_fragment = true,
  macro = true,
  export_snippet = true,
  inline_src_block = true,
  inline_babel_call = true,
  statistics_cookie = true,
  target = true,
  line_break = true,
}

local function esc(s)
  return (s:gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\n", "\\n"))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function child(node, ty)
  for c in node:iter_children() do
    if c:type() == ty then
      return c
    end
  end
end

-- One document's dump.  `starts[r]` is the byte offset of row r (0-based).
local function dump(src)
  local starts = { [0] = 0 }
  do
    local r = 0
    for i = 1, #src do
      if src:byte(i) == 10 then
        r = r + 1
        starts[r] = i
      end
    end
  end
  local function offset(row, col)
    return (starts[row] or #src) + col
  end
  local function pos(off)
    local lo, hi = 0, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= off then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return string.format("%d:%d", lo + 1, off - starts[lo])
  end
  local function text(node)
    return vim.treesitter.get_node_text(node, src)
  end

  local records = {}
  local seq = 0
  local skip = {}

  local function record_range(b, e, ty, props)
    while e > b and src:sub(e, e):match("[ \t\n]") do
      e = e - 1
    end
    while b < e and src:sub(b + 1, b + 1):match("[ \t\n]") do
      b = b + 1
    end
    seq = seq + 1
    records[#records + 1] = { b = b, e = e, seq = seq, ty = ty, props = props or {} }
    return records[#records]
  end

  local function record(node, ty, props)
    local sr, sc, er, ec = node:range()
    return record_range(offset(sr, sc), offset(er, ec), ty, props)
  end

  local function line_of(r)
    local parts = { string.format("%s %s-%s", r.ty, pos(r.b), pos(r.e)) }
    for _, kv in ipairs(r.props) do
      if kv[2] and kv[2] ~= "" then
        parts[#parts + 1] = kv[1] .. "=" .. esc(kv[2])
      end
    end
    return table.concat(parts, " ")
  end

  local function headline_props(line)
    local props = { { "level", nil } }
    local todo, priority, commented, tags = nil, nil, nil, {}
    local _, _, er, ec = line:range()
    local title_from, title_to = 0, offset(er, ec)
    for c, field in line:iter_children() do
      local csr, csc, cer, cec = c:range()
      if field == "stars" then
        props[1][2] = tostring(#trim(text(c)))
        title_from = offset(cer, cec)
      elseif field == "todo" then
        if keywords[text(c)] then
          todo = text(c)
          title_from = offset(cer, cec)
        end
      elseif field == "priority" then
        priority = text(c):match("^%[#(.*)%]$")
        title_from = offset(cer, cec)
      elseif field == "comment" then
        commented = "t"
        title_from = offset(cer, cec)
      elseif field == "tag_list" then
        title_to = offset(csr, csc)
        for t in c:iter_children() do
          if t:type() == "tag" then
            tags[#tags + 1] = text(t)
          end
        end
      end
    end
    props[#props + 1] = { "todo", todo }
    props[#props + 1] = { "priority", priority }
    props[#props + 1] = { "commented", commented }
    props[#props + 1] = { "tags", table.concat(tags, ",") }
    props[#props + 1] = { "title", trim(src:sub(title_from + 1, title_to)) }
    return props
  end

  local walk

  local function walk_children(node)
    local pending = {}
    local last
    for c in node:iter_children() do
      if c:named() then
        local ty = c:type()
        if ty == "formula" and last and last.ty == "table" then
          last.tblfm = last.tblfm + 1
        elseif ty == "affiliated_keyword" then
          pending[#pending + 1] = c
        else
          local rec = walk(c, pending)
          if rec then
            pending = {}
            last = rec
          end
        end
      end
    end
    for _, a in ipairs(pending) do
      walk(a)
    end
  end

  local function aff_props(props, aff)
    if not aff or #aff == 0 then
      return props
    end
    local keys, seen, name = {}, {}, nil
    for _, a in ipairs(aff) do
      local k = text(a:field("name")[1]):upper()
      if not seen[k] then
        seen[k] = true
        keys[#keys + 1] = k
      end
      if k == "NAME" then
        local v = a:field("value")[1]
        name = v and trim(text(v)) or ""
      end
    end
    table.sort(keys)
    props[#props + 1] = { "aff", table.concat(keys, ",") }
    props[#props + 1] = { "name", name }
    return props
  end

  -- Records `node` (and its subtree); returns { ty = ..., rec = ... } for
  -- an element, nil for a node that is not one.
  walk = function(node, aff)
    local ty = node:type()
    local function el(name, props)
      local rec = record(node, name, aff_props(props or {}, aff))
      return { ty = name, rec = rec }
    end
    local out
    if ty == "headline" or ty == "inlinetask" then
      local line = child(node, ty == "headline" and "headline_line" or "inlinetask_line")
      out = el(ty, line and headline_props(line) or {})
      if line then
        local cookie = line:field("cookie")[1]
        if cookie then
          record(cookie, "statistics-cookie")
        end
      end
      local first, last_end
      for c in node:iter_children() do
        local cty = c:type()
        if cty == "planning" or cty == "property_drawer" or cty == "section" then
          local sr, sc, er, ec = c:range()
          first = first or offset(sr, sc)
          last_end = offset(er, ec)
        end
      end
      if first then
        record_range(first, last_end, "section")
      end
      for c in node:iter_children() do
        if c:type() == "section" then
          walk_children(c)
        elseif c:named() then
          walk(c)
        end
      end
      return out
    elseif ty == "planning" then
      local props = {}
      for pl in node:iter_children() do
        for entry in pl:iter_children() do
          if entry:type() == "planning_entry" then
            local k = entry:field("keyword")[1]
            local t = entry:field("timestamp")[1]
            if k and t then
              props[#props + 1] = { trim(text(k)):gsub(":$", ""):lower(), text(t) }
            end
          end
        end
      end
      table.sort(props, function(a, b)
        return a[1] < b[1]
      end)
      out = el("planning", props)
      skip[#skip + 1] = out.rec
      return out
    elseif ty == "clock" then
      local d = node:field("duration")[1]
      out = el("clock", { { "duration", d and trim(text(d)) } })
      skip[#skip + 1] = out.rec
      return out
    elseif ty == "node_property" then
      local k, v = node:field("name")[1], node:field("value")[1]
      return el("node-property", { { "key", k and text(k) }, { "value", v and trim(text(v)) } })
    elseif ty == "drawer" then
      local n = child(node, "drawer_name")
      out = el("drawer", { { "name", n and text(n) } })
    elseif ty == "greater_block" then
      local n = child(node, "block_name")
      local name = n and text(n) or ""
      if GREATER[name:lower()] then
        out = el(GREATER[name:lower()])
      else
        out = el("special-block", { { "type", name } })
      end
    elseif ty == "dynamic_block" then
      local n = node:field("name")[1]
      out = el("dynamic-block", { { "name", n and text(n) } })
    elseif ty == "src_block" then
      local n = child(node, "src_block_language")
      return el("src-block", { { "language", n and text(n) } })
    elseif ty == "export_block" then
      local n = child(node, "export_format")
      return el("export-block", { { "type", n and text(n):upper() } })
    elseif ty == "list_item" then
      local props = {}
      local b, c, ck, tag =
        node:field("bullet")[1],
        node:field("counter")[1],
        node:field("checkbox")[1],
        node:field("item_tag")[1]
      props[1] = { "bullet", b and trim(text(b)) }
      local counter = c and text(c):match("^%[@(.-)%]")
      if counter and counter:match("^%a$") then
        counter = tostring(counter:lower():byte() - 96)
      end
      props[2] = { "counter", counter }
      local box = ck and trim(text(ck)):sub(2, 2)
      props[3] = {
        "checkbox",
        box and (box == " " and "off" or box == "-" and "trans" or "on"),
      }
      props[4] = { "tag", tag and trim(text(tag)) }
      out = el("item", props)
    elseif ty == "table" then
      out = el("table", { { "type", "org" } })
      out.tblfm = 0
      walk_children(node)
      out.rec.tblfm = out
      return out
    elseif ty == "table_row" or ty == "table_header_row" then
      out = el("table-row", { { "type", "standard" } })
    elseif ty == "table_rule" then
      return el("table-row", { { "type", "rule" } })
    elseif ty == "footnote_definition" then
      local l = node:field("label")[1]
      out = el("footnote-definition", { { "label", l and text(l) } })
    elseif ty == "keyword" or ty == "affiliated_keyword" or ty == "formula" then
      local k, v = node:field("name")[1], node:field("value")[1]
      return el("keyword", { { "key", k and text(k):upper() }, { "value", v and trim(text(v)) } })
    elseif ty == "diary_sexp" then
      return el("diary-sexp", { { "value", trim(text(node)) } })
    elseif SIMPLE[ty] then
      out = el(SIMPLE[ty])
    end
    walk_children(node)
    return out
  end

  local lt = vim.treesitter.get_string_parser(src, "org")
  lt:parse(true)
  walk_children(lt:trees()[1]:root())

  local seen = {}
  local function walk_inline(node)
    local ty = node:type()
    local name = OBJECTS[ty] or (TIMESTAMPS[ty] and "timestamp")
    if name then
      local sr, sc, er, ec = node:range()
      local b = offset(sr, sc)
      local inside = false
      for _, r in ipairs(skip) do
        if b >= r.b and b <= r.e then
          inside = true
        end
      end
      local key = string.format("%s:%d:%d", ty, b, offset(er, ec))
      if not inside and not seen[key] then
        seen[key] = true
        local props = {}
        if TIMESTAMPS[ty] then
          local kind = TIMESTAMPS[ty]
          if child(node, "ts_time_range") and not kind:match("range") then
            kind = kind .. "-range"
          end
          props[1] = { "type", kind }
        end
        record(node, name, props)
      end
    end
    if LEAVES[ty] or TIMESTAMPS[ty] then
      return
    end
    for c in node:iter_children() do
      if c:named() then
        walk_inline(c)
      end
    end
  end
  for lang, sub in pairs(lt:children()) do
    if lang == "org_inline" then
      for _, t in ipairs(sub:trees()) do
        walk_inline(t:root())
      end
    end
  end

  table.sort(records, function(a, b)
    if a.b ~= b.b then
      return a.b < b.b
    elseif a.e ~= b.e then
      return a.e > b.e
    end
    return a.seq < b.seq
  end)
  local lines = {}
  for _, r in ipairs(records) do
    if r.tblfm and r.tblfm.tblfm > 0 then
      table.insert(r.props, 2, { "tblfm", tostring(r.tblfm.tblfm) })
    end
    lines[#lines + 1] = line_of(r)
  end
  local file_id
  for _, h in ipairs(extract.extract(src, "case.org", nil)) do
    if h.level == 0 then
      file_id = h.id
    else
      local props = {
        { "level", tostring(h.level) },
        { "todo", h.todo_state },
        { "priority", h.priority },
        { "commented", h.commented == 1 and "t" or nil },
        { "tags", table.concat(h.tags or {}, ",") },
        { "title", h.title },
      }
      local parts = { "entry" }
      for _, kv in ipairs(props) do
        if kv[2] and kv[2] ~= "" then
          parts[#parts + 1] = kv[1] .. "=" .. esc(kv[2])
        end
      end
      lines[#lines + 1] = table.concat(parts, " ")
    end
  end
  if file_id then
    lines[#lines + 1] = "file-id " .. esc(file_id)
  end
  return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

local function documents(textin)
  if not textin:find("\n=====\n", 1, true) then
    return { textin }
  end
  local docs = {}
  local start = 1
  while true do
    local s, e = textin:find("\n=====\n", start, true)
    if not s then
      docs[#docs + 1] = textin:sub(start)
      break
    end
    docs[#docs + 1] = textin:sub(start, s)
    start = e + 1
  end
  return docs
end

return {
  render = function(path)
    local f = assert(io.open(path, "rb"))
    local textin = f:read("*a")
    f:close()
    local docs = documents(textin)
    local out = {}
    for i, doc in ipairs(docs) do
      if #docs > 1 then
        out[#out + 1] = string.format("##### %d\n", i)
      end
      out[#out + 1] = dump(doc)
    end
    return table.concat(out)
  end,
}
