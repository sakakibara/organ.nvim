-- BibTeX (.bib) parser. Recognises the standard entry shape:
--
--   @<type>{<key>,
--     <field> = {<braced value>} | "<quoted value>" | <bare-token>,
--     ...
--   }
--
-- Values may be joined with `#`; bare tokens resolve against earlier
-- `@string` definitions. Text outside entries is a comment. Returns
-- one parsed entry per `@` block; M.normalize splits author / editor /
-- year strings into structured form usable by the renderer, decodes
-- LaTeX accent commands and drops the braces left outside a LaTeX
-- fragment -- or, under `opts.raw`, leaves every value as written.

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function collapse_ws(s)
  return (s:gsub("[ \t\r\n]+", " "))
end

local ACCENTS = {
  ['"'] = {
    a = "ä",
    e = "ë",
    i = "ï",
    o = "ö",
    u = "ü",
    y = "ÿ",
    A = "Ä",
    E = "Ë",
    I = "Ï",
    O = "Ö",
    U = "Ü",
    Y = "Ÿ",
  },
  ["'"] = {
    a = "á",
    e = "é",
    i = "í",
    o = "ó",
    u = "ú",
    y = "ý",
    c = "ć",
    n = "ń",
    s = "ś",
    z = "ź",
    A = "Á",
    E = "É",
    I = "Í",
    O = "Ó",
    U = "Ú",
    Y = "Ý",
    C = "Ć",
    N = "Ń",
    S = "Ś",
    Z = "Ź",
  },
  ["`"] = {
    a = "à",
    e = "è",
    i = "ì",
    o = "ò",
    u = "ù",
    A = "À",
    E = "È",
    I = "Ì",
    O = "Ò",
    U = "Ù",
  },
  ["^"] = {
    a = "â",
    e = "ê",
    i = "î",
    o = "ô",
    u = "û",
    A = "Â",
    E = "Ê",
    I = "Î",
    O = "Ô",
    U = "Û",
  },
  ["~"] = { a = "ã", n = "ñ", o = "õ", A = "Ã", N = "Ñ", O = "Õ" },
  ["="] = {
    a = "ā",
    e = "ē",
    i = "ī",
    o = "ō",
    u = "ū",
    A = "Ā",
    E = "Ē",
    I = "Ī",
    O = "Ō",
    U = "Ū",
  },
  ["."] = { c = "ċ", e = "ė", g = "ġ", z = "ż", C = "Ċ", E = "Ė", G = "Ġ", Z = "Ż" },
  u = { a = "ă", g = "ğ", A = "Ă", G = "Ğ" },
  v = {
    c = "č",
    d = "ď",
    e = "ě",
    n = "ň",
    r = "ř",
    s = "š",
    t = "ť",
    z = "ž",
    C = "Č",
    D = "Ď",
    E = "Ě",
    N = "Ň",
    R = "Ř",
    S = "Š",
    T = "Ť",
    Z = "Ž",
  },
  H = { o = "ő", u = "ű", O = "Ő", U = "Ű" },
  c = { c = "ç", s = "ş", t = "ţ", C = "Ç", S = "Ş", T = "Ţ" },
  k = { a = "ą", e = "ę", A = "Ą", E = "Ę" },
  r = { a = "å", u = "ů", A = "Å", U = "Ů" },
}

local COMMANDS = {
  ss = "ß",
  o = "ø",
  O = "Ø",
  ae = "æ",
  AE = "Æ",
  oe = "œ",
  OE = "Œ",
  aa = "å",
  AA = "Å",
  l = "ł",
  L = "Ł",
  i = "ı",
}

local function accent(kind, base)
  base = base:gsub("[{}]", ""):gsub("^\\([ij])$", "%1")
  return ACCENTS[kind][base]
end

-- Spans org reads as a LaTeX fragment: math, and a command with a braced
-- argument.  Their braces are markup rather than BibTeX capitalisation
-- guards, so they pass through untouched -- verified by exporting a .bib
-- through Emacs and reading the output.
local FRAGMENTS = {
  "%$%$.-%$%$",
  "\\%[.-\\%]",
  "\\%(.-\\%)",
  "%$.-%$",
  "\\%a+%b{}",
}

-- Earliest fragment at or after `init`; the longest one wins a tie so
-- `$$x$$` reads as display math rather than two empty inline ones.
local function next_fragment(s, init)
  local bs, be
  for _, pat in ipairs(FRAGMENTS) do
    local a, b = s:find(pat, init)
    if a and (not bs or a < bs or (a == bs and b > be)) then
      bs, be = a, b
    end
  end
  return bs, be
end

local function decode_outside_fragments(s)
  s = s:gsub("\\(%a+)%f[%A]", COMMANDS)
  s = s:gsub("\\([&%%_#])", "%1")
  return (s:gsub("[{}]", ""))
end

-- Decode LaTeX accent commands and escaped specials, then drop the braces
-- left outside any LaTeX fragment.
local function decode_latex(s)
  s = s:gsub("\\{", "\2"):gsub("\\}", "\3"):gsub("\\%$", "\4")
  s = s:gsub("\\([\"'`%^~=%.])(%b{})", accent)
  s = s:gsub("\\([\"'`%^~=%.])(\\?%a)", accent)
  s = s:gsub("\\([uvHckr])(%b{})", accent)
  s = s:gsub("\\([uvHckr]) (%a)", accent)
  local out, pos = {}, 1
  while true do
    local a, b = next_fragment(s, pos)
    if not a then
      break
    end
    out[#out + 1] = decode_outside_fragments(s:sub(pos, a - 1))
    out[#out + 1] = s:sub(a, b)
    pos = b + 1
  end
  out[#out + 1] = decode_outside_fragments(s:sub(pos))
  return (table.concat(out):gsub("\2", "{"):gsub("\3", "}"):gsub("\4", "$"))
end

-- Split `s` at every depth-0 character for which `is_sep` holds.
local function split_depth0(s, is_sep)
  local out, buf, depth = {}, {}, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
    end
    if depth == 0 and is_sep(c) then
      out[#out + 1] = table.concat(buf)
      buf = {}
    else
      buf[#buf + 1] = c
    end
  end
  out[#out + 1] = table.concat(buf)
  return out
end

-- Split a BibTeX name list joined by `and` into individual names.
-- Aware of brace-protected names (`{van der Berg}`).
local function split_names(s)
  s = collapse_ws(s)
  local out = {}
  local depth = 0
  local buf = ""
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "{" then
      depth = depth + 1
      buf = buf .. c
    elseif c == "}" then
      depth = depth - 1
      buf = buf .. c
    elseif depth == 0 and s:sub(i, i + 4):lower() == " and " then
      out[#out + 1] = trim(buf)
      buf = ""
      i = i + 4
    else
      buf = buf .. c
    end
    i = i + 1
  end
  if trim(buf) ~= "" then
    out[#out + 1] = trim(buf)
  end
  return out
end

local function clean(s)
  return trim(decode_latex(s))
end

-- Parse a single BibTeX name into { family = ..., given = ..., suffix = ... }.
--   "Doe, John"             -> family="Doe", given="John"
--   "John Doe"              -> family="Doe", given="John"
--   "Doe, Jr., John"        -> family="Doe", given="John", suffix="Jr."
--   "{van der Berg}, Jan"   -> family="van der Berg", given="Jan"
--   "Ludwig van Beethoven"  -> family="van Beethoven", given="Ludwig"
local function parse_name(s, tidy)
  tidy = tidy or clean
  s = collapse_ws(trim(s))
  local parts = split_depth0(s, function(c)
    return c == ","
  end)
  if #parts >= 3 then
    return { family = tidy(parts[1]), suffix = tidy(parts[2]), given = tidy(parts[3]) }
  elseif #parts == 2 then
    return { family = tidy(parts[1]), given = tidy(parts[2]) }
  end
  local words = {}
  for _, w in
    ipairs(split_depth0(s, function(c)
      return c == " "
    end))
  do
    if w ~= "" then
      words[#words + 1] = w
    end
  end
  if #words == 0 then
    return { family = "", given = "" }
  end
  if #words == 1 then
    return { family = tidy(words[1]), given = "" }
  end
  -- "First von Last": the family part starts at the first
  -- lowercase-initial word, else at the last word.
  local family_start = #words
  for i = 1, #words - 1 do
    if words[i]:match("^%l") then
      family_start = i
      break
    end
  end
  return {
    family = tidy(table.concat(words, " ", family_start, #words)),
    given = family_start > 1 and tidy(table.concat(words, " ", 1, family_start - 1)) or "",
  }
end

local function skip_ws(text, pos)
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      pos = pos + 1
    elseif c == "%" then
      while pos <= #text and text:sub(pos, pos) ~= "\n" do
        pos = pos + 1
      end
    else
      break
    end
  end
  return pos
end

-- Read a brace-delimited block (handles nesting). pos points at the
-- opening "{". Returns the content and the position after the closing "}".
local function read_braced(text, pos)
  local start = pos + 1
  local depth = 1
  pos = pos + 1
  while pos <= #text and depth > 0 do
    local c = text:sub(pos, pos)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
    end
    if depth > 0 then
      pos = pos + 1
    end
  end
  return text:sub(start, pos - 1), pos + 1
end

-- Read a quoted value; a `"` inside braces does not terminate it.
local function read_quoted(text, pos)
  local start = pos + 1
  local depth = 0
  pos = pos + 1
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
    elseif c == '"' and depth <= 0 then
      break
    end
    pos = pos + 1
  end
  return text:sub(start, pos - 1), pos + 1
end

local function read_bare(text, pos)
  local start = pos
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == "," or c == "}" or c == ")" or c == "#" or c:match("%s") then
      break
    end
    pos = pos + 1
  end
  return text:sub(start, pos - 1), pos
end

-- Read a field value: one or more `#`-joined pieces, each braced,
-- quoted, or a bare token (number or `@string` macro).
local function read_value(text, pos, strings)
  local parts = {}
  while true do
    pos = skip_ws(text, pos)
    local first = text:sub(pos, pos)
    local piece
    if first == "{" then
      piece, pos = read_braced(text, pos)
    elseif first == '"' then
      piece, pos = read_quoted(text, pos)
    else
      piece, pos = read_bare(text, pos)
      piece = strings[piece:lower()] or piece
    end
    parts[#parts + 1] = piece
    pos = skip_ws(text, pos)
    if text:sub(pos, pos) ~= "#" then
      break
    end
    pos = pos + 1
  end
  return table.concat(parts), pos
end

local function skip_to_closer(text, pos, opener, closer)
  local depth = 1
  while pos <= #text and depth > 0 do
    local c = text:sub(pos, pos)
    if c == opener then
      depth = depth + 1
    elseif c == closer then
      depth = depth - 1
    end
    if depth > 0 then
      pos = pos + 1
    end
  end
  return pos + 1
end

local function parse_entry(text, pos, strings)
  local tstart = pos
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == "{" or c == "(" or c:match("%s") then
      break
    end
    pos = pos + 1
  end
  local etype = text:sub(tstart, pos - 1):lower()
  pos = skip_ws(text, pos)
  local opener = text:sub(pos, pos)
  if opener ~= "{" and opener ~= "(" then
    return nil, pos
  end
  local closer = (opener == "{") and "}" or ")"
  pos = pos + 1
  pos = skip_ws(text, pos)

  if etype == "string" then
    local nstart = pos
    while pos <= #text and text:sub(pos, pos) ~= "=" and text:sub(pos, pos) ~= closer do
      pos = pos + 1
    end
    if text:sub(pos, pos) == "=" then
      local name = trim(text:sub(nstart, pos - 1)):lower()
      local value
      value, pos = read_value(text, pos + 1, strings)
      strings[name] = value
    end
    return nil, skip_to_closer(text, pos, opener, closer)
  end
  if etype == "comment" or etype == "preamble" then
    return nil, skip_to_closer(text, pos, opener, closer)
  end

  local kstart = pos
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == "," or c == closer then
      break
    end
    pos = pos + 1
  end
  local key = trim(text:sub(kstart, pos - 1))
  if text:sub(pos, pos) == "," then
    pos = pos + 1
  end

  local fields = {}
  while pos <= #text do
    pos = skip_ws(text, pos)
    if text:sub(pos, pos) == closer then
      pos = pos + 1
      break
    end
    local fstart = pos
    while pos <= #text and text:sub(pos, pos) ~= "=" do
      local c = text:sub(pos, pos)
      if c == "," or c == closer then
        break
      end
      pos = pos + 1
    end
    if text:sub(pos, pos) ~= "=" then
      break
    end
    local fname = trim(text:sub(fstart, pos - 1)):lower()
    local value
    value, pos = read_value(text, pos + 1, strings)
    fields[fname] = collapse_ws(value)

    pos = skip_ws(text, pos)
    if text:sub(pos, pos) == "," then
      pos = pos + 1
    end
  end

  return { type = etype, key = key, fields = fields }, pos
end

function M.parse(text)
  if not text or text == "" then
    return {}
  end
  local entries, strings = {}, {}
  local pos = 1
  while true do
    pos = text:find("@", pos, true)
    if not pos then
      break
    end
    local entry
    entry, pos = parse_entry(text, pos + 1, strings)
    if entry then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

-- Convenience: read a .bib file from disk and parse it.
function M.parse_file(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local text = f:read("*a")
  f:close()
  return M.parse(text)
end

local function parse_names(s, tidy)
  local out = {}
  for _, name in ipairs(split_names(s)) do
    out[#out + 1] = parse_name(name, tidy)
  end
  return out
end

-- Walk parsed entries; pull author / editor name lists into structured
-- form, parse year as a number where possible, decode LaTeX in every
-- field. Returns the input list (mutated in place) for chainability.
--
-- `opts.raw` keeps every value exactly as the .bib wrote it, for backends
-- that compile the LaTeX themselves.
function M.normalize(entries, opts)
  local tidy = (opts and opts.raw) and trim or clean
  for _, e in ipairs(entries) do
    if e.fields.author then
      e.author = parse_names(e.fields.author, tidy)
    end
    if e.fields.editor then
      e.editor = parse_names(e.fields.editor, tidy)
    end
    if e.fields.year then
      e.year = tonumber(e.fields.year:match("%d+"))
    end
    for fname, value in pairs(e.fields) do
      e.fields[fname] = tidy(value)
    end
  end
  return entries
end

-- Build an O(1)-lookup index from key -> entry.
function M.index(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[e.key] = e
  end
  return out
end

M._parse_name = parse_name

return M
