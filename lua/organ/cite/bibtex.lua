-- BibTeX (.bib) parser. Recognises the standard entry shape:
--
--   @<type>{<key>,
--     <field> = {<braced value>} | "<quoted value>" | <bare-token>,
--     ...
--   }
--
-- with nested braces inside field values, // and % line-comment
-- handling, and `and`-joined author lists. Returns one parsed entry
-- per `@` block; M.normalize splits author / editor / year strings
-- into structured form usable by the renderer.

local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Strip outer braces and superfluous whitespace.  "{John Doe}" → "John Doe".
-- BibTeX uses braces both for delimiting AND for case-protection; we
-- discard the outermost level only, which preserves single inner
-- braces around proper nouns (e.g. "{Linux}").
local function strip_outer_braces(s)
  s = trim(s)
  while #s >= 2 and s:sub(1, 1) == "{" and s:sub(-1) == "}" do
    -- Only strip if the outer braces are matched as a single pair.
    local depth = 0
    local matched = true
    for i = 1, #s do
      local c = s:sub(i, i)
      if c == "{" then
        depth = depth + 1
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 and i ~= #s then
          matched = false
          break
        end
      end
    end
    if matched then
      s = trim(s:sub(2, -2))
    else
      break
    end
  end
  return s
end

-- Split a BibTeX name list joined by `and` into individual names.
-- Aware of brace-protected names (`{van der Berg}`).
local function split_names(s)
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

-- Parse a single BibTeX name into { family = ..., given = ... }.
-- Supports both BibTeX conventions:
--   "Doe, John"           → family="Doe", given="John"
--   "John Doe"            → family="Doe", given="John"
--   "Doe, John, Sr."      → family="Doe", given="John", suffix="Sr."
--   "{van der Berg}, Jan" → family="van der Berg", given="Jan"
local function parse_name(s)
  s = strip_outer_braces(s)
  -- Comma form
  local parts = {}
  local depth = 0
  local buf = ""
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "{" then
      depth = depth + 1
      buf = buf .. c
    elseif c == "}" then
      depth = depth - 1
      buf = buf .. c
    elseif c == "," and depth == 0 then
      parts[#parts + 1] = trim(buf)
      buf = ""
    else
      buf = buf .. c
    end
  end
  parts[#parts + 1] = trim(buf)
  if #parts >= 2 then
    return {
      family = strip_outer_braces(parts[1]),
      given = strip_outer_braces(parts[2]),
      suffix = parts[3] and strip_outer_braces(parts[3]) or nil,
    }
  end
  -- "First Last" form: last word is family.
  local words = {}
  for w in s:gmatch("%S+") do
    words[#words + 1] = w
  end
  if #words == 0 then
    return { family = "", given = "" }
  end
  if #words == 1 then
    return { family = words[1], given = "" }
  end
  return {
    family = words[#words],
    given = table.concat(words, " ", 1, #words - 1),
  }
end

-- Tokeniser-friendly entry parser. Tracks position with explicit `pos`
-- so we can recover from junk between entries.

local function skip_ws(text, pos)
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      pos = pos + 1
    elseif c == "%" then
      -- BibTeX line comment.
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
  return text:sub(start, pos - 1), pos + 1 -- skip closing }
end

local function read_quoted(text, pos)
  local start = pos + 1
  pos = pos + 1
  while pos <= #text and text:sub(pos, pos) ~= '"' do
    pos = pos + 1
  end
  return text:sub(start, pos - 1), pos + 1 -- skip closing "
end

local function read_bare(text, pos)
  local start = pos
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == "," or c == "}" or c == ")" or c == " " or c == "\t" or c == "\n" or c == "\r" then
      break
    end
    pos = pos + 1
  end
  return text:sub(start, pos - 1), pos
end

local function parse_entry(text, pos)
  -- Already past `@`. Read entry type.
  local tstart = pos
  while pos <= #text do
    local c = text:sub(pos, pos)
    if c == "{" or c == "(" or c == " " or c == "\t" or c == "\n" or c == "\r" then
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

  -- Special entry types: @string, @comment, @preamble. Skip them.
  if etype == "string" or etype == "comment" or etype == "preamble" then
    -- Skip to matching closer.
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
    return nil, pos + 1
  end

  -- Read citation key.
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
    pos = pos + 1 -- past `=`
    pos = skip_ws(text, pos)

    local value
    local first = text:sub(pos, pos)
    if first == "{" then
      value, pos = read_braced(text, pos)
    elseif first == '"' then
      value, pos = read_quoted(text, pos)
    else
      value, pos = read_bare(text, pos)
    end
    fields[fname] = value

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
  local entries = {}
  local pos = 1
  while pos <= #text do
    pos = skip_ws(text, pos)
    if text:sub(pos, pos) ~= "@" then
      break
    end
    pos = pos + 1
    local entry
    entry, pos = parse_entry(text, pos)
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

-- Walk parsed entries; pull author / editor name lists into structured
-- form, parse year as a number where possible. Returns the input list
-- (mutated in place) for chainability.
function M.normalize(entries)
  for _, e in ipairs(entries) do
    if e.fields.author then
      e.author = {}
      for _, name in ipairs(split_names(e.fields.author)) do
        e.author[#e.author + 1] = parse_name(name)
      end
    end
    if e.fields.editor then
      e.editor = {}
      for _, name in ipairs(split_names(e.fields.editor)) do
        e.editor[#e.editor + 1] = parse_name(name)
      end
    end
    if e.fields.year then
      e.year = tonumber(e.fields.year:match("%d+"))
    end
    -- Strip outer braces from common text fields so renderers don't
    -- see them.
    for _, fname in ipairs({
      "title",
      "journal",
      "booktitle",
      "publisher",
      "address",
      "note",
      "abstract",
    }) do
      if e.fields[fname] then
        e.fields[fname] = strip_outer_braces(e.fields[fname])
      end
    end
  end
  return entries
end

-- Build an O(1)-lookup index from key → entry.
function M.index(entries)
  local out = {}
  for _, e in ipairs(entries) do
    out[e.key] = e
  end
  return out
end

M._parse_name = parse_name

return M
