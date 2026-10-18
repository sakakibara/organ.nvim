-- Canonical one-node-per-line form of an HTML document for the html
-- conformance gate; NORMALIZE.md gives the reason for every rule.  The
-- Emacs side's generated `orgXXXXXXX` ids are first mapped onto the ids
-- organ gave the same elements, which organ.lua records per case.

local entities = require("organ.ast.html5_entities")

local VOID = {}
for n in ("area base br col embed hr img input link meta source track wbr"):gmatch("%S+") do
  VOID[n] = true
end

local BLOCK = {}
for n in
  ([[html head body title meta link style script div p h1 h2 h3 h4 h5 h6 ul ol li dl dt dd
  table caption colgroup col thead tbody tfoot tr th td pre blockquote hr br nav section
  article aside header footer figure figcaption center main details summary textarea]]):gmatch(
    "%S+"
  )
do
  BLOCK[n] = true
end

local LEGACY = {}
for n in
  ([[AElig AMP Aacute Acirc Agrave Aring Atilde Auml COPY Ccedil ETH Eacute Ecirc Egrave Euml
  GT Iacute Icirc Igrave Iuml LT Ntilde Oacute Ocirc Ograve Oslash Otilde Ouml QUOT REG THORN
  Uacute Ucirc Ugrave Uuml Yacute aacute acirc acute aelig agrave amp aring atilde auml brvbar
  ccedil cedil cent copy curren deg divide eacute ecirc egrave eth euml frac12 frac14 frac34 gt
  iacute icirc iexcl igrave iquest iuml laquo lt macr micro middot nbsp not ntilde oacute ocirc
  ograve ordf ordm oslash otilde ouml para plusmn pound quot raquo reg sect shy sup1 sup2 sup3
  szlig thorn times uacute ucirc ugrave uml uuml yacute yen yuml]]):gmatch("%S+")
do
  LEGACY[n] = true
end

local GENERATED = "%f[%w]org%x%x%x%x%x%x%x%f[%W]"

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

local function decode(s)
  return (
    s:gsub("&(#?)([%w]+)(;?)", function(hash, name, semi)
      if hash == "#" then
        local cp = name:match("^[xX](%x+)$")
        cp = cp and tonumber(cp, 16) or (name:match("^%d+$") and tonumber(name))
        if cp then
          return utf8_char(cp)
        end
        return nil
      end
      if semi == ";" and entities[name] then
        return entities[name]
      end
      for i = #name, 2, -1 do
        local head = name:sub(1, i)
        if LEGACY[head] and entities[head] then
          return entities[head] .. name:sub(i + 1) .. semi
        end
      end
      return nil
    end)
  )
end

local function encode(s, attr)
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  if attr then
    s = s:gsub('"', "&quot;")
  end
  return (
    s:gsub("[\192-\247][\128-\191]*", function(c)
      local cp = vim.fn.char2nr(c, true)
      return string.format("&#x%x;", cp)
    end)
  )
end

local function parse_attrs(src)
  local attrs, seen = {}, {}
  local i = 1
  while i <= #src do
    local s, e, name = src:find("^[%s/]*([^%s=/>\"']+)", i)
    if not s then
      break
    end
    i = e + 1
    local value = ""
    local vs, ve, q = src:find("^%s*=%s*([\"'])", i)
    if vs then
      local close = src:find(q, ve + 1, true) or (#src + 1)
      value = src:sub(ve + 1, close - 1)
      i = close + 1
    else
      local us, ue, v = src:find("^%s*=%s*([^%s>]+)", i)
      if us then
        value = v
        i = ue + 1
      end
    end
    name = name:lower()
    if not seen[name] then
      seen[name] = true
      attrs[#attrs + 1] = { name = name, value = decode(value) }
    end
  end
  return attrs
end

--- Tokens of an HTML text: { kind = "tag"|"end"|"text"|"raw"|"other", ... }.
local function tokenize(html)
  local toks = {}
  local i = 1
  local n = #html
  while i <= n do
    local lt = html:find("<", i, true)
    if not lt then
      toks[#toks + 1] = { kind = "text", text = html:sub(i) }
      break
    end
    if lt > i then
      toks[#toks + 1] = { kind = "text", text = html:sub(i, lt - 1) }
    end
    if html:sub(lt, lt + 3) == "<!--" then
      local e = html:find("-->", lt + 4, true) or (n - 2)
      toks[#toks + 1] = { kind = "other", text = html:sub(lt, e + 2) }
      i = e + 3
    elseif html:match("^<[!?]", lt) then
      local e = html:find(">", lt, true) or n
      toks[#toks + 1] = { kind = "other", text = html:sub(lt, e) }
      i = e + 1
    else
      local close, name = html:match("^<(/?)([%a][%w%-]*)", lt)
      if not name then
        toks[#toks + 1] = { kind = "text", text = "<" }
        i = lt + 1
      else
        local e = lt + 1
        local q
        while e <= n do
          local c = html:sub(e, e)
          if q then
            if c == q then
              q = nil
            end
          elseif c == '"' or c == "'" then
            q = c
          elseif c == ">" then
            break
          end
          e = e + 1
        end
        name = name:lower()
        if close == "/" then
          toks[#toks + 1] = { kind = "end", name = name }
        else
          local body = html:sub(lt + 1 + #name, e - 1)
          toks[#toks + 1] = { kind = "tag", name = name, attrs = parse_attrs(body) }
          if name == "style" or name == "script" then
            local cs = html:find("</" .. name, e + 1, true) or (n + 1)
            toks[#toks + 1] = { kind = "raw", text = html:sub(e + 1, cs - 1) }
            e = cs - 1
          end
        end
        i = e + 1
      end
    end
  end
  return toks
end

local function attr(tok, name)
  for _, a in ipairs(tok.attrs) do
    if a.name == name then
      return a.value
    end
  end
end

-- The element kind an id is paired by: tag (any heading level is "h"),
-- anchors without href and plain spans as one kind, plus the class list.
local function id_kind(tok)
  local name = tok.name
  if name:match("^h%d$") then
    name = "h"
  elseif (name == "a" and not attr(tok, "href")) or name == "span" then
    name = "anchor"
  end
  return name .. "." .. (attr(tok, "class") or "")
end

local function ids_by_kind(toks)
  local out = {}
  for _, t in ipairs(toks) do
    local id = t.kind == "tag" and attr(t, "id")
    if id then
      local k = id_kind(t)
      out[k] = out[k] or {}
      table.insert(out[k], id)
    end
  end
  return out
end

-- Map every generated id of the Emacs text to the organ id at the same
-- position among elements of the same kind; an organ id already taken
-- gets a "--dup<n>" suffix so the map stays one-to-one.  A generated id
-- with no such element is dropped when nothing in the document refers to
-- it, and otherwise becomes "emacs-id-<kind>-<n>"; one on no element
-- becomes "emacs-ref-<n>", numbered by first occurrence.
local function map_ids(emacs_html, organ_html)
  local etoks = tokenize(emacs_html)
  local okinds = ids_by_kind(tokenize(organ_html or ""))
  local map = {}
  local pos = {}
  local used = {}
  for _, t in ipairs(etoks) do
    local id = t.kind == "tag" and attr(t, "id")
    if id and not id:match("^org%x%x%x%x%x%x%x$") then
      used[id] = true
    end
  end
  for _, t in ipairs(etoks) do
    local id = t.kind == "tag" and attr(t, "id")
    if id then
      local k = id_kind(t)
      pos[k] = (pos[k] or 0) + 1
      if id:match("^org%x%x%x%x%x%x%x$") and not map[id] then
        local theirs = okinds[k] and okinds[k][pos[k]]
        if theirs then
          local to, n = theirs, 1
          while used[to] do
            n = n + 1
            to = string.format("%s--dup%d", theirs, n)
          end
          used[to] = true
          map[id] = to
        elseif select(2, emacs_html:gsub(id, "")) == 1 then
          map[id] = false
        else
          map[id] = string.format("emacs-id-%s-%d", (k:gsub("[^%w]+", "-")), pos[k])
        end
      end
    end
  end
  for id, to in pairs(map) do
    if to == false then
      emacs_html = emacs_html:gsub('%s+id="' .. id .. '"', "")
    end
  end
  local refs = 0
  return (
    emacs_html:gsub(GENERATED, function(tok)
      if not map[tok] then
        refs = refs + 1
        map[tok] = "emacs-ref-" .. refs
      end
      return map[tok]
    end)
  )
end

local function serialize_tag(t)
  local attrs = vim.deepcopy(t.attrs)
  table.sort(attrs, function(a, b)
    return a.name < b.name
  end)
  local parts = { "<" .. t.name }
  for _, a in ipairs(attrs) do
    parts[#parts + 1] = string.format('%s="%s"', a.name, encode(a.value, true))
  end
  return table.concat(parts, " ") .. ">"
end

local function is_block(t)
  return t and (t.kind == "other" or ((t.kind == "tag" or t.kind == "end") and BLOCK[t.name]))
end

-- True when token i starts (dir -1) or ends (dir 1) a rendered line: only
-- inline start tags (before) or inline end tags (after), and whitespace,
-- separate it from a block boundary or the document edge.
local function at_line_edge(toks, i, dir)
  local skip = dir < 0 and "tag" or "end"
  local j = i + dir
  while
    toks[j]
    and (
      (toks[j].kind == skip and not BLOCK[toks[j].name] and not VOID[toks[j].name])
      or (toks[j].kind == "text" and not toks[j].text:match("[^ \t\n\r\f]"))
    )
  do
    j = j + dir
  end
  return toks[j] == nil or is_block(toks[j])
end

-- True when only end tags follow token i up to the enclosing </pre>.
local function closes_pre(toks, i)
  for j = i + 1, #toks do
    local t = toks[j]
    if t.kind ~= "end" then
      return false
    end
    if t.name == "pre" then
      return true
    end
  end
  return false
end

-- Drop <p></p> pairs holding nothing but whitespace.
local function drop_empty_paragraphs(toks)
  local out = {}
  local i = 1
  while i <= #toks do
    local t = toks[i]
    local j = i + 1
    if toks[j] and toks[j].kind == "text" and not toks[j].text:match("[^ \t\n\r\f]") then
      j = j + 1
    end
    if
      t.kind == "tag"
      and t.name == "p"
      and #t.attrs == 0
      and toks[j]
      and toks[j].kind == "end"
      and toks[j].name == "p"
    then
      i = j + 1
    else
      out[#out + 1] = t
      i = i + 1
    end
  end
  return out
end

local function render(toks)
  local lines = {}
  local comments = {}
  local pre = 0
  local after_pre_open = false
  for i, t in ipairs(toks) do
    if t.kind == "tag" then
      lines[#lines + 1] = serialize_tag(t)
      if t.name == "pre" then
        pre = pre + 1
        after_pre_open = true
      end
    elseif t.kind == "end" then
      if not VOID[t.name] then
        lines[#lines + 1] = "</" .. t.name .. ">"
      end
      if t.name == "pre" and pre > 0 then
        pre = pre - 1
      end
    elseif t.kind == "raw" then
      if t.text:match("%S") then
        lines[#lines + 1] = string.format("#raw sha256:%s", vim.fn.sha256(t.text):sub(1, 16))
      end
    elseif t.kind == "other" and t.text:sub(1, 4) == "<!--" then
      comments[#comments + 1] = (t.text:gsub("%s+", " "))
    elseif t.kind == "other" then
      lines[#lines + 1] = (t.text:gsub("%s+", " "))
    elseif pre > 0 then
      local text = t.text
      if after_pre_open then
        text = text:gsub("^\r?\n", "")
      end
      if closes_pre(toks, i) then
        text = text:gsub("\n$", "")
      end
      if text ~= "" then
        for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
          lines[#lines + 1] = "|" .. encode(decode(l))
        end
      end
    else
      local text = t.text:gsub("[ \t\n\r\f]+", " ")
      if at_line_edge(toks, i, -1) then
        text = text:gsub("^ ", "")
      end
      if at_line_edge(toks, i, 1) then
        text = text:gsub(" $", "")
      end
      if text ~= "" then
        lines[#lines + 1] = encode(decode(text))
      end
    end
    if t.kind ~= "tag" or t.name ~= "pre" then
      after_pre_open = false
    end
  end
  vim.list_extend(lines, comments)
  return table.concat(lines, "\n") .. "\n"
end

-- Sort key of a head child: metas first (charset declarations, then the
-- viewport, then by name), scripts, the title, then styles and
-- stylesheet links; the sort is stable, so scripts keep their execution
-- order and styles their cascade order.
local function head_key(t)
  if t.name == "meta" then
    if attr(t, "charset") or attr(t, "http-equiv") then
      return "0 0"
    end
    local name = attr(t, "name") or attr(t, "property") or ""
    return name == "viewport" and "0 1" or ("0 2 " .. name)
  elseif t.name == "script" then
    return "1"
  elseif t.name == "title" then
    return "2"
  end
  return "3"
end

local DEFAULT_TYPE = { style = "text/css", script = "text/javascript" }

local function canonical_head(toks)
  local hs, he
  for i, t in ipairs(toks) do
    if t.kind == "tag" and t.name == "head" and not hs then
      hs = i
    elseif t.kind == "end" and t.name == "head" and hs then
      he = i
      break
    end
  end
  for _, t in ipairs(toks) do
    if t.kind == "tag" and DEFAULT_TYPE[t.name] then
      local kept = {}
      for _, a in ipairs(t.attrs) do
        if not (a.name == "type" and a.value:lower() == DEFAULT_TYPE[t.name]) then
          kept[#kept + 1] = a
        end
      end
      t.attrs = kept
    end
  end
  if not he then
    return toks
  end
  local units, loose = {}, {}
  local i = hs + 1
  while i < he do
    local t = toks[i]
    if t.kind == "tag" then
      local unit = { t }
      if not VOID[t.name] then
        local j = i + 1
        while j < he and not (toks[j].kind == "end" and toks[j].name == t.name) do
          unit[#unit + 1] = toks[j]
          j = j + 1
        end
        unit[#unit + 1] = toks[j]
        i = j
      end
      units[#units + 1] = { key = head_key(t), pos = #units, toks = unit }
    elseif t.kind ~= "text" or t.text:match("%S") then
      loose[#loose + 1] = t
    end
    i = i + 1
  end
  table.sort(units, function(a, b)
    if a.key ~= b.key then
      return a.key < b.key
    end
    return a.pos < b.pos
  end)
  local out = {}
  for k = 1, hs do
    out[#out + 1] = toks[k]
  end
  vim.list_extend(out, loose)
  for _, u in ipairs(units) do
    vim.list_extend(out, u.toks)
  end
  for k = he, #toks do
    out[#out + 1] = toks[k]
  end
  return out
end

local cases_dir = vim.fn.getcwd() .. "/tests/conformance/html/cases"

return function(text, side, case)
  if not text:match("^%s*<") then
    return text
  end
  text = text:gsub(vim.pesc(cases_dir), "CASES")
  if side == "emacs" then
    local organ = package.loaded["conformance.html.organ"]
    text = map_ids(text, organ and organ.rendered[case])
  end
  return render(drop_empty_paragraphs(canonical_head(tokenize(text))))
end
