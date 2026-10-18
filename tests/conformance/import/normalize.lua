-- Import gate normalizer: rewrites each example's HTML, on both sides,
-- into one canonical line form so that only differences in what the HTML
-- means remain.  Every rule is listed and justified in NORMALIZE.md.
-- Error lines (ORGAN-ERROR / EMACS-ERROR) pass through unchanged.

local VOID = {}
for t in ("area base br col embed hr img input link meta param source track wbr"):gmatch("%S+") do
  VOID[t] = true
end

local BLOCK = {}
for t in
  (
    "address article aside blockquote body center details dialog dd dir div dl dt fieldset "
    .. "figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html "
    .. "iframe legend li link main menu menuitem nav noframes ol optgroup option p param "
    .. "search section summary table tbody td tfoot th thead title tr track ul pre script "
    .. "style textarea footnotes fn"
  ):gmatch("%S+")
do
  BLOCK[t] = true
end

local VERBATIM = { pre = true, script = true, style = true, textarea = true }
local RAWTEXT = { script = true, style = true }

local BOOLEAN = {}
for t in
  ("checked disabled selected open hidden readonly required multiple autofocus async defer"):gmatch(
    "%S+"
  )
do
  BOOLEAN[t] = true
end

local ENTITIES = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = "\194\160",
  ndash = "\226\128\147",
  mdash = "\226\128\148",
  hellip = "\226\128\166",
  shy = "\194\173",
  lsquo = "\226\128\152",
  rsquo = "\226\128\153",
  ldquo = "\226\128\156",
  rdquo = "\226\128\157",
  copy = "\194\169",
  alpha = "\206\177",
  beta = "\206\178",
  rarr = "\226\134\146",
  ouml = "\195\182",
  auml = "\195\164",
}

local function utf8_char(n)
  if n == 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF) then
    n = 0xFFFD
  end
  return vim.fn.nr2char(n, true)
end

local function decode(s)
  s = s:gsub("&#[xX](%x+);", function(h)
    return utf8_char(tonumber(h, 16))
  end)
  s = s:gsub("&#(%d+);", function(d)
    return utf8_char(tonumber(d))
  end)
  return (s:gsub("&(%a%w*);", function(name)
    return ENTITIES[name]
  end))
end

local function escape_text(s)
  return (
    s:gsub("&", "&amp;")
      :gsub("<", "&lt;")
      :gsub(">", "&gt;")
      :gsub("\194\160", "&#xa0;")
      :gsub("\226\128\139", "&#x200b;")
  )
end

local function escape_attr(s)
  return (s:gsub("&", "&amp;"):gsub('"', "&quot;"))
end

-- Tokenizer: text, open (tag, attrs, self), close (tag), raw (comment,
-- declaration, processing instruction, CDATA, kept verbatim).

local function parse_attrs(s, i)
  local attrs = {}
  while true do
    i = s:match("^%s*()", i)
    if s:sub(i, i + 1) == "/>" then
      return attrs, i + 2, true
    elseif s:sub(i, i) == ">" then
      return attrs, i + 1, false
    end
    local name, j = s:match("^([^%s\"'>/=]+)()", i)
    if not name then
      return nil
    end
    i = j
    local value = ""
    local k = s:match("^%s*=%s*()", i)
    if k then
      local q = s:sub(k, k)
      if q == '"' or q == "'" then
        local close = s:find(q, k + 1, true)
        if not close then
          return nil
        end
        value = s:sub(k + 1, close - 1)
        i = close + 1
      else
        local v, e = s:match("^([^%s\"'=<>`]+)()", k)
        if not v then
          return nil
        end
        value, i = v, e
      end
    end
    attrs[#attrs + 1] = { name:lower(), decode(value) }
  end
end

local function tokenize(s)
  local toks, i, n = {}, 1, #s
  local function text(t)
    if #toks > 0 and toks[#toks].kind == "text" then
      toks[#toks].s = toks[#toks].s .. t
    else
      toks[#toks + 1] = { kind = "text", s = t }
    end
  end
  while i <= n do
    local lt = s:find("<", i, true)
    if not lt then
      text(decode(s:sub(i)))
      break
    end
    if lt > i then
      text(decode(s:sub(i, lt - 1)))
    end
    i = lt
    local rest = s:sub(i, i + 8)
    local stop
    if rest:sub(1, 5) == "<!-->" then
      stop = i + 4
    elseif rest:sub(1, 6) == "<!--->" then
      stop = i + 5
    elseif rest:sub(1, 4) == "<!--" then
      local e = s:find("-->", i + 4, true)
      stop = e and e + 2 or n
    elseif rest == "<![CDATA[" then
      local e = s:find("]]>", i + 9, true)
      stop = e and e + 2 or n
    elseif rest:sub(1, 2) == "<?" then
      local e = s:find("?>", i + 2, true)
      stop = e and e + 1 or n
    elseif rest:match("^<![%a]") then
      local e = s:find(">", i + 2, true)
      stop = e or n
    end
    if stop then
      toks[#toks + 1] = { kind = "raw", s = s:sub(i, stop) }
      i = stop + 1
    else
      local ctag, cend = s:match("^</([%a][%w%-]*)%s*>()", i)
      local otag, oend = s:match("^<([%a][%w%-]*)()", i)
      if ctag then
        toks[#toks + 1] = { kind = "close", tag = ctag:lower() }
        i = cend
      elseif otag then
        local attrs, e, self = parse_attrs(s, oend)
        if attrs then
          local tag = otag:lower()
          toks[#toks + 1] = { kind = "open", tag = tag, attrs = attrs, self = self }
          i = e
          if VERBATIM[tag] and tag ~= "pre" then
            local stop_at = s:lower():find("</" .. tag, i, true) or (n + 1)
            local body = s:sub(i, stop_at - 1)
            if #body > 0 then
              text(RAWTEXT[tag] and body or decode(body))
            end
            i = stop_at
          end
        else
          text("<")
          i = i + 1
        end
      else
        text("<")
        i = i + 1
      end
    end
  end
  return toks
end

-- Tree: element { tag, attrs = {name = value}, children }, text { text },
-- raw { raw }.  A close tag with no open match stays as raw text.
local function build(toks)
  local root = { tag = "#root", attrs = {}, children = {} }
  local stack = { root }
  for _, t in ipairs(toks) do
    local top = stack[#stack]
    if t.kind == "text" then
      top.children[#top.children + 1] = { text = t.s }
    elseif t.kind == "raw" then
      top.children[#top.children + 1] = { raw = t.s }
    elseif t.kind == "open" then
      local attrs = {}
      for _, a in ipairs(t.attrs) do
        if attrs[a[1]] == nil then
          attrs[a[1]] = a[2]
        end
      end
      local el = { tag = t.tag, attrs = attrs, children = {} }
      top.children[#top.children + 1] = el
      if not VOID[t.tag] then
        stack[#stack + 1] = el
      end
    else
      local found
      for k = #stack, 2, -1 do
        if stack[k].tag == t.tag then
          found = k
          break
        end
      end
      if found then
        for k = #stack, found, -1 do
          stack[k] = nil
        end
      elseif not VOID[t.tag] then
        top.children[#top.children + 1] = { raw = "</" .. t.tag .. ">" }
      end
    end
  end
  return root
end

local function classes(el)
  local set = {}
  for c in (el.attrs.class or ""):gmatch("%S+") do
    set[c] = true
  end
  return set
end

local function text_of(node)
  if node.text then
    return node.text
  end
  local parts = {}
  for _, c in ipairs(node.children or {}) do
    parts[#parts + 1] = text_of(c)
  end
  return table.concat(parts)
end

local function find_child(el, tag)
  for _, c in ipairs(el.children or {}) do
    if c.tag == tag then
      return c
    end
  end
end

-- Class tokens ox-html generates and the spec's renderer-specific ones;
-- language and alignment classes are read before this filter runs.
local GENERATED_CLASS = {
  "^org%-",
  "^outline%-%d+$",
  "^outline%-text%-%d+$",
  "^footref$",
  "^footnum$",
  "^footdef$",
  "^footpara$",
  "^figure$",
  "^src$",
  "^src%-",
  "^example$",
  "^on$",
  "^off$",
  "^trans$",
  "^language%-",
}

local function generated_class(c)
  for _, p in ipairs(GENERATED_CLASS) do
    if c:match(p) then
      return true
    end
  end
  return false
end

local function generated_id(id)
  return id:match("^org%x%x%x%x%x%x%x$") ~= nil
end

local UNRESERVED = "[%w%-%._~]"

-- Percent-escapes for a space, a non-ASCII byte or an unreserved character
-- name the same URL as the character itself (RFC 3986 6.2.2.2; WHATWG URL
-- parsing escapes space and non-ASCII), so both spellings become the
-- character.
local function canon_url(u)
  return (
    u:gsub("%%(%x%x)", function(h)
      local b = tonumber(h, 16)
      local c = string.char(b)
      if b == 32 or b >= 128 or c:match(UNRESERVED) then
        return c
      end
      return "%" .. h:upper()
    end)
  )
end

local canon_children

-- One footnote section: { tag = "footnotes", children = { fn ... } }.
local function footnotes_from_spec(section)
  local out = { tag = "footnotes", attrs = {}, children = {} }
  local ol = find_child(section, "ol")
  local n = 0
  for _, li in ipairs(ol and ol.children or {}) do
    if li.tag == "li" then
      n = n + 1
      out.children[#out.children + 1] =
        { tag = "fn", attrs = { n = tostring(n) }, children = li.children }
    end
  end
  return out
end

local function footnotes_from_org(div)
  local out = { tag = "footnotes", attrs = {}, children = {} }
  local body = find_child(div, "div") or { children = {} }
  for _, def in ipairs(body.children) do
    if def.tag == "div" and classes(def).footdef then
      local num = find_child(def, "sup")
      local para = find_child(def, "div")
      out.children[#out.children + 1] = {
        tag = "fn",
        attrs = { n = vim.trim(num and text_of(num) or "?") },
        children = para and para.children or {},
      }
    end
  end
  return out
end

local function footnote_ref(el)
  if el.tag ~= "sup" then
    return nil
  end
  local a = find_child(el, "a")
  if a and (classes(el)["footnote-ref"] or classes(a).footref) then
    return { tag = "fnref", attrs = { n = vim.trim(text_of(a)) }, children = {} }
  end
end

local function canon_attrs(el, ids)
  local a = {}
  local cls = {}
  for c in (el.attrs.class or ""):gmatch("%S+") do
    if not generated_class(c) then
      cls[#cls + 1] = c
    end
  end
  for k, v in pairs(el.attrs) do
    if k == "class" then
      if #cls > 0 then
        a.class = table.concat(cls, " ")
      end
    elseif k == "id" then
      if not generated_id(v) then
        a.id = v
      end
    elseif (k == "href" or k == "src") and v ~= "" then
      local frag = v:match("^#(.*)$")
      if frag and ids[frag] then
        a[k] = "#" .. ids[frag]
      else
        a[k] = canon_url(v)
      end
    elseif BOOLEAN[k] then
      a[k] = true
    else
      a[k] = v
    end
  end
  if el.tag == "table" then
    for _, k in ipairs({ "border", "cellspacing", "cellpadding", "rules", "frame" }) do
      a[k] = nil
    end
  elseif el.tag == "td" or el.tag == "th" then
    local align = el.attrs.align
    local style = (el.attrs.style or ""):match("text%-align:%s*(%a+)")
    local cls_align = (" " .. (el.attrs.class or "") .. " "):match("%sorg%-(%a+)%s")
    align = align or style or cls_align
    a.align = align
    a.scope = nil
    if style then
      a.style = nil
    end
  elseif el.tag == "input" and (el.attrs.type or ""):lower() == "checkbox" then
    a.disabled = nil
  elseif el.tag == "a" then
    a.role = nil
  end
  return a
end

local function canon_pre(el, ids)
  local attrs = canon_attrs(el, ids)
  for c in pairs(classes(el)) do
    attrs.lang = attrs.lang or c:match("^src%-(.+)$")
  end
  local kids = el.children
  if #kids == 1 and kids[1].tag == "code" then
    for c in pairs(classes(kids[1])) do
      attrs.lang = attrs.lang or c:match("^language%-(.+)$")
    end
    kids = kids[1].children
  elseif kids[1] and kids[1].text and kids[1].text:sub(1, 1) == "\n" then
    kids = vim.list_extend({ { text = kids[1].text:sub(2) } }, vim.list_slice(kids, 2))
  end
  return { tag = "pre", attrs = attrs, children = kids, verbatim = true }
end

-- ox-html's bold and italic markup and the spec's strong and em.
local MARKUP = { b = "strong", i = "em" }
local NBSP = "\194\160"

local function canon(node, ids)
  if node.text or node.raw then
    return { node }
  end
  local el = node
  local cls = classes(el)
  if el.tag == "div" then
    for c in pairs(cls) do
      if
        c:match("^outline%-%d+$")
        or c:match("^outline%-text%-%d+$")
        or c == "org-src-container"
        or c == "figure"
      then
        return canon_children(el.children, ids)
      end
    end
    if el.attrs.id == "footnotes" then
      return { canon(footnotes_from_org(el), ids)[1] }
    end
  elseif el.tag == "section" and cls.footnotes then
    return { canon(footnotes_from_spec(el), ids)[1] }
  elseif el.tag == "colgroup" or el.tag == "col" then
    return {}
  elseif el.tag == "a" and cls["footnote-backref"] then
    return {}
  elseif el.tag == "sup" then
    local ref = footnote_ref(el)
    if ref then
      return { ref }
    end
  elseif el.tag == "pre" then
    local p = canon_pre(el, ids)
    p.children = canon_children(p.children, ids)
    return { p }
  elseif el.tag == "footnotes" or el.tag == "fn" then
    return { { tag = el.tag, attrs = el.attrs, children = canon_children(el.children, ids) } }
  end
  local out = { tag = MARKUP[el.tag] or el.tag, attrs = canon_attrs(el, ids), children = {} }
  out.verbatim = VERBATIM[el.tag]
  out.children = canon_children(el.children, ids)
  if (el.tag == "td" or el.tag == "th") and #out.children == 1 and out.children[1].text == NBSP then
    out.children = {}
  end
  if el.tag == "ol" then
    local n = tonumber(el.attrs.start or "") or 1
    out.attrs.start = nil
    for _, li in ipairs(out.children) do
      if li.tag == "li" then
        local v = tonumber(li.attrs.value or "")
        if v then
          n = v
        end
        li.attrs.value = nil
        li.attrs.n = tostring(n)
        n = n + 1
      end
    end
  end
  return { out }
end

canon_children = function(children, ids)
  local out = {}
  for _, c in ipairs(children) do
    vim.list_extend(out, canon(c, ids))
  end
  return out
end

-- Serialization: block elements open and close on their own lines; a run
-- of inline content is one line with HTML whitespace collapsed; the
-- content of pre, script, style and textarea is kept verbatim.

local function open_tag(el)
  local keys = vim.tbl_keys(el.attrs)
  table.sort(keys)
  local parts = { "<" .. el.tag }
  for _, k in ipairs(keys) do
    local v = el.attrs[k]
    parts[#parts + 1] = v == true and k or (k .. '="' .. escape_attr(v) .. '"')
  end
  return table.concat(parts, " ") .. (VOID[el.tag] and " />" or ">")
end

local function inline(node, verbatim)
  if node.text then
    local t = node.text
    if not verbatim then
      t = t:gsub("[ \t\n\r\f]+", " ")
    end
    return escape_text(t)
  elseif node.raw then
    return node.raw
  end
  local parts = { open_tag(node) }
  for _, c in ipairs(node.children) do
    parts[#parts + 1] = inline(c, verbatim or node.verbatim)
  end
  if not VOID[node.tag] then
    parts[#parts + 1] = "</" .. node.tag .. ">"
  end
  return table.concat(parts)
end

-- Collapse whitespace across inline element boundaries and drop it next
-- to a block-level tag, where HTML renders none.
local function tidy_run(s)
  local out, pos, space = {}, 1, true
  local function gap(text)
    text = text:gsub(" +", " ")
    if space then
      text = text:gsub("^ ", "")
    end
    if text ~= "" then
      out[#out + 1] = text
      space = text:sub(-1) == " "
    end
  end
  for st, tag, en in s:gmatch("()(<[^>]*>)()") do
    gap(s:sub(pos, st - 1))
    local name = tag:match("^</?([%w%-]+)")
    if name and BLOCK[name:lower()] then
      if #out > 0 and space then
        out[#out] = out[#out]:gsub(" $", "")
      end
      space = true
    end
    out[#out + 1] = tag
    pos = en
  end
  gap(s:sub(pos))
  return vim.trim(table.concat(out))
end

local function serialize(children, lines)
  local run = {}
  local function flush()
    local s = tidy_run(table.concat(run))
    if s ~= "" then
      lines[#lines + 1] = s
    end
    run = {}
  end
  for _, c in ipairs(children) do
    if c.tag and BLOCK[c.tag] then
      flush()
      lines[#lines + 1] = open_tag(c)
      if c.verbatim then
        local parts = {}
        for _, k in ipairs(c.children) do
          parts[#parts + 1] = inline(k, true)
        end
        local body = table.concat(parts):gsub("\n$", "")
        if body ~= "" then
          vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
        end
      else
        serialize(c.children, lines)
      end
      if not VOID[c.tag] then
        lines[#lines + 1] = "</" .. c.tag .. ">"
      end
    else
      run[#run + 1] = inline(c, false)
    end
  end
  flush()
end

-- Fragment links to an id Emacs generated name the element that carries
-- the id, so a link to the right element is told from one to a wrong one.
local function generated_targets(node, ids)
  if node.tag then
    local id = node.attrs.id
    if id and generated_id(id) then
      ids[id] = string.format("[%s %s]", node.tag, vim.trim(text_of(node):gsub("%s+", " ")))
    end
    for _, c in ipairs(node.children) do
      generated_targets(c, ids)
    end
  end
end

local function canonical(html)
  local tree = build(tokenize(html))
  local ids = {}
  generated_targets(tree, ids)
  local lines = {}
  serialize(canon_children(tree.children, ids), lines)
  return lines
end

return function(text, _side, _case)
  local out = {}
  local label, body = nil, {}
  local function emit()
    if label then
      out[#out + 1] = label
      local html = table.concat(body, "\n")
      if html:match("^ORGAN%-ERROR: ") or html:match("^EMACS%-ERROR: ") then
        out[#out + 1] = vim.trim(html)
      else
        vim.list_extend(out, canonical(html))
      end
    end
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if line:match("^=== .* ===$") then
      emit()
      label, body = line, {}
    else
      body[#body + 1] = line
    end
  end
  emit()
  return table.concat(out, "\n") .. "\n"
end
