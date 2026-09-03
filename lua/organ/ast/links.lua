-- Link destination resolution shared by the export renderers: file
-- links get the backend's extension, `*Title` / `#custom-id` / `id:`
-- links and bare fuzzy links resolve to the anchor of a headline or
-- `<<target>>` in the same document.

local A = require("organ.ast")

local M = {}

-- Keep non-ASCII bytes (so a Japanese/accented phrase yields a distinct,
-- non-empty id instead of collapsing to ""); hex-fallback if still empty.
function M.slug(phrase)
  local s = (phrase or ""):lower():gsub("[%s%p]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if s == "" then
    s = "r-"
      .. (phrase or ""):gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end)
  end
  return s
end

function M.plain_text(nodes)
  local out = {}
  for _, n in ipairs(nodes or {}) do
    if n.kind == "text" or n.kind == "raw_inline" then
      out[#out + 1] = n.text or ""
    elseif n.kind == "link" then
      out[#out + 1] = (n.description and #n.description > 0) and M.plain_text(n.description)
        or (n.target or "")
    elseif n.content then
      out[#out + 1] = M.plain_text(n.content)
    end
  end
  return table.concat(out)
end

function M.headline_anchor(h)
  local custom = h.properties and h.properties.CUSTOM_ID
  if custom and custom ~= "" then
    return custom
  end
  return M.slug(M.plain_text(h.title))
end

function M.target_anchor(name)
  return M.slug(name)
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Every destination a link in `doc` can point at.
function M.index(doc)
  local idx = { titles = {}, custom_ids = {}, ids = {}, targets = {} }
  A.walk(doc, function(n)
    if n.kind == "headline" then
      local entry = { kind = "headline", anchor = M.headline_anchor(n), node = n }
      local title = trim(M.plain_text(n.title))
      if not idx.titles[title] then
        idx.titles[title] = entry
      end
      local p = n.properties or {}
      if p.CUSTOM_ID and p.CUSTOM_ID ~= "" then
        idx.custom_ids[p.CUSTOM_ID] = entry
      end
      if p.ID and p.ID ~= "" then
        idx.ids[p.ID] = entry
      end
    elseif n.kind == "target" then
      local name = trim(n.name or "")
      if not idx.targets[name] then
        idx.targets[name] = { kind = "target", anchor = M.target_anchor(name) }
      end
    end
  end)
  return idx
end

local EMPTY = { titles = {}, custom_ids = {}, ids = {}, targets = {} }
local UNRESOLVED = { kind = "unresolved" }

local function resolve_file(path, ext)
  local search
  local base, rest = path:match("^(.-)::(.*)$")
  if base then
    path, search = base, rest
  end
  if ext and path:lower():match("%.org$") then
    path = path:sub(1, -5) .. ext
  end
  local fragment
  if search and search ~= "" then
    if search:sub(1, 1) == "#" then
      fragment = search:sub(2)
    elseif search:sub(1, 1) == "*" then
      fragment = M.slug(trim(search:sub(2)))
    else
      fragment = M.slug(trim(search))
    end
  end
  return { kind = "file", path = path, fragment = fragment }
end

-- Resolve `target` against `idx` (from M.index; nil means an empty
-- document).  `ext` replaces the `.org` extension of file links.
-- Returns one of:
--   { kind = "external", url = target }
--   { kind = "file", path = "...", fragment = "..." | nil }
--   { kind = "headline", anchor = "...", node = headline }
--   { kind = "target", anchor = "..." }
--   { kind = "unresolved" }
function M.resolve(target, idx, ext)
  idx = idx or EMPTY
  target = target or ""
  local scheme, rest = target:match("^(%a[%w+.-]*):(.*)$")
  if scheme == "file" then
    return resolve_file(rest, ext)
  elseif scheme == "id" then
    return idx.ids[rest] or UNRESOLVED
  elseif scheme then
    return { kind = "external", url = target }
  end
  local first = target:sub(1, 1)
  if first == "#" then
    return idx.custom_ids[target:sub(2)] or UNRESOLVED
  elseif first == "*" then
    return idx.titles[trim(target:sub(2))] or UNRESOLVED
  elseif target:match("^%.?%.?/") or first == "~" then
    return resolve_file(target, ext)
  end
  local key = trim(target)
  return idx.targets[key] or idx.titles[key] or UNRESOLVED
end

return M
