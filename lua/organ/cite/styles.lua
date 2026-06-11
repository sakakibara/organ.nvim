-- Built-in citation styles. Three ship in the initial cut:
--
--   apa      — author-date, alphabetical bibliography
--              In-text:    (Doe & Smith, 2020)
--              Bib:        Doe, J., & Smith, J. (2020). Title. Journal, 1(2), 3–5.
--   chicago  — author-date variant of Chicago
--              In-text:    (Doe and Smith 2020)
--              Bib:        Doe, John, and Jane Smith. 2020. "Title." Journal 1(2): 3–5.
--   ieee     — numeric, occurrence-ordered bibliography
--              In-text:    [1]
--              Bib:        [1] J. Doe and J. Smith, "Title," Journal, vol. 1, no. 2, pp. 3–5, 2020.
--
-- Each style is a table of two functions:
--
--   render_cite(parsed_cite, bib_index, ctx) -> string
--   render_bibliography(bib_index, used_keys, ctx) -> { string, ... }
--
-- `ctx` is per-render scratch (e.g. ieee maintains a key→number map
-- so the same key gets the same number across all in-text refs).
--
-- Year-disambiguation: when two entries share author family + year,
-- author-date styles append a/b/c suffixes ("Doe 2020a", "Doe 2020b").
-- The suffix is computed lazily on first cite via _year_suffixes(ctx,
-- bib_index) so the renderer doesn't need to know about it.
--
-- Per-cite prefix/suffix from the org-cite parser are honoured: a
-- suffix like "p. 5" is appended inside the parens, and prefix like
-- "see" is prepended before the author name.

local M = {}

-- Helpers shared by multiple styles.

local function authors_short_apa(authors)
  if not authors or #authors == 0 then
    return ""
  end
  if #authors == 1 then
    return authors[1].family
  end
  if #authors == 2 then
    return authors[1].family .. " & " .. authors[2].family
  end
  return authors[1].family .. " et al."
end

local function authors_short_chicago(authors)
  if not authors or #authors == 0 then
    return ""
  end
  if #authors == 1 then
    return authors[1].family
  end
  if #authors == 2 then
    return authors[1].family .. " and " .. authors[2].family
  end
  return authors[1].family .. " et al."
end

local function initials(given)
  if not given or given == "" then
    return ""
  end
  local parts = {}
  for w in given:gmatch("%S+") do
    local letter = w:sub(1, 1)
    if letter:match("[%w]") then
      parts[#parts + 1] = letter:upper() .. "."
    end
  end
  return table.concat(parts, " ")
end

-- "Doe, J., & Smith, J." (APA) / "Doe, John, and Jane Smith" (Chicago)
local function authors_full_apa(authors)
  if not authors or #authors == 0 then
    return ""
  end
  local pieces = {}
  for _, a in ipairs(authors) do
    pieces[#pieces + 1] = a.family .. (a.given ~= "" and ", " .. initials(a.given) or "")
  end
  if #pieces == 1 then
    return pieces[1]
  end
  if #pieces == 2 then
    return pieces[1] .. ", & " .. pieces[2]
  end
  return table.concat(pieces, ", ", 1, #pieces - 1) .. ", & " .. pieces[#pieces]
end

local function authors_full_chicago(authors)
  if not authors or #authors == 0 then
    return ""
  end
  local pieces = {}
  for i, a in ipairs(authors) do
    if i == 1 then
      pieces[i] = a.family .. (a.given ~= "" and ", " .. a.given or "")
    else
      pieces[i] = (a.given ~= "" and a.given .. " " or "") .. a.family
    end
  end
  if #pieces == 1 then
    return pieces[1]
  end
  if #pieces == 2 then
    return pieces[1] .. ", and " .. pieces[2]
  end
  return table.concat(pieces, ", ", 1, #pieces - 1) .. ", and " .. pieces[#pieces]
end

local function authors_full_ieee(authors)
  if not authors or #authors == 0 then
    return ""
  end
  local pieces = {}
  for _, a in ipairs(authors) do
    pieces[#pieces + 1] = (a.given ~= "" and initials(a.given) .. " " or "") .. a.family
  end
  if #pieces == 1 then
    return pieces[1]
  end
  if #pieces == 2 then
    return pieces[1] .. " and " .. pieces[2]
  end
  return table.concat(pieces, ", ", 1, #pieces - 1) .. ", and " .. pieces[#pieces]
end

local function en_dash_pages(s)
  if not s then
    return nil
  end
  return s:gsub("%-%-", "–"):gsub("%-", "–")
end

-- Italics for journal/book titles. Each backend wants a different wrapper
-- (`<em>` for HTML, `\emph{}` for LaTeX, `/.../` for org). We emit a
-- private sentinel `\1IT\1text\1IT\1` so render.lua can substitute the
-- appropriate wrapper at the end. The control byte \1 cannot appear in
-- normal text, which makes the substitution unambiguous.
local IT = "\1IT\1"
local function italic(s)
  return IT .. s .. IT
end

-- Compute year suffixes: { ["doe2020a"] = "a", ["doe2020b"] = "b", ... }.
-- A suffix is added only when two or more entries share the (family, year)
-- pair. Stored on ctx so we don't recompute per-cite.
local function year_suffixes(ctx, bib_index)
  if ctx._year_suffixes then
    return ctx._year_suffixes
  end
  -- group by family|year
  local groups = {}
  for k, e in pairs(bib_index) do
    local family = (e.author and e.author[1] and e.author[1].family) or ""
    local year = e.year or ""
    local g = family .. "|" .. year
    groups[g] = groups[g] or {}
    groups[g][#groups[g] + 1] = k
  end
  local out = {}
  for _, keys in pairs(groups) do
    if #keys > 1 then
      table.sort(keys) -- deterministic
      for i, k in ipairs(keys) do
        out[k] = string.char(96 + i) -- 'a','b','c',...
      end
    end
  end
  ctx._year_suffixes = out
  return out
end

-- Year for a key, with disambiguation suffix appended if any. Returns
-- "" when the entry has no year.
local function disambiguated_year(ctx, bib_index, key)
  local e = bib_index[key]
  if not e or not e.year then
    return ""
  end
  local sfx = year_suffixes(ctx, bib_index)[key] or ""
  return e.year .. sfx
end

-- For the bibliography heading: "(2020a)." vs "(2020)." Use the same
-- disambiguation for sorting and display.
local function disambiguated_year_str(ctx, bib_index, e)
  local sfx = year_suffixes(ctx, bib_index)[e.key] or ""
  return e.year and (e.year .. sfx) or nil
end

-- Sort key for alphabetical bibliographies. Combines family + year so
-- multiple entries by the same author are grouped chronologically, then
-- the disambiguation suffix breaks ties.
local function alpha_key(e, sfx_map)
  local family = (e.author and e.author[1] and e.author[1].family) or e.key or ""
  local year = e.year or 0
  local sfx = sfx_map[e.key] or ""
  return string.lower(family) .. "\0" .. string.format("%08d", year) .. sfx
end

-- APA

M.apa = {}

function M.apa.render_cite(parsed, bib_index, ctx)
  ctx = ctx or {}
  local refs = {}
  for _, r in ipairs(parsed.refs or {}) do
    local entry = bib_index[r.key]
    local body
    if entry then
      local year = disambiguated_year(ctx, bib_index, r.key)
      if parsed.style == "noauthor" or parsed.style == "year" then
        body = year
      elseif parsed.style == "author" then
        body = authors_short_apa(entry.author)
      else
        body = authors_short_apa(entry.author) .. (year ~= "" and ", " .. year or "")
      end
    else
      body = r.key
    end
    -- Per-key prefix / suffix from org-cite syntax.
    if r.prefix and r.prefix ~= "" then
      body = r.prefix .. " " .. body
    end
    if r.suffix and r.suffix ~= "" then
      body = body .. ", " .. r.suffix
    end
    refs[#refs + 1] = body
  end
  if parsed.style == "author" then
    -- Bare authors don't sit inside parens.
    return table.concat(refs, "; ")
  end
  return "(" .. table.concat(refs, "; ") .. ")"
end

local function apa_format_entry(e, ctx, bib_index)
  local s = authors_full_apa(e.author)
  local year = disambiguated_year_str(ctx, bib_index, e)
  if year then
    s = s .. " (" .. year .. ")."
  else
    s = s .. "."
  end
  if e.fields.title then
    s = s .. " " .. e.fields.title .. "."
  end
  if e.fields.journal then
    s = s .. " " .. italic(e.fields.journal)
    if e.fields.volume then
      s = s .. ", " .. italic(e.fields.volume)
      if e.fields.number then
        s = s .. "(" .. e.fields.number .. ")"
      end
    end
    if e.fields.pages then
      s = s .. ", " .. en_dash_pages(e.fields.pages)
    end
    s = s .. "."
  elseif e.type == "inproceedings" or e.type == "incollection" or e.type == "inbook" then
    if e.fields.booktitle then
      s = s .. " In " .. italic(e.fields.booktitle)
      if e.fields.pages then
        s = s .. " (pp. " .. en_dash_pages(e.fields.pages) .. ")"
      end
      s = s .. "."
    end
    if e.fields.publisher then
      s = s .. " " .. e.fields.publisher .. "."
    end
  elseif e.fields.publisher then
    s = s .. " " .. e.fields.publisher .. "."
  elseif e.type == "thesis" or e.type == "phdthesis" or e.type == "mastersthesis" then
    local kind = (e.type == "phdthesis" and "Doctoral dissertation")
      or (e.type == "mastersthesis" and "Master's thesis")
      or "Thesis"
    s = s .. " [" .. kind .. (e.fields.school and ", " .. e.fields.school or "") .. "]."
  end
  if e.fields.doi then
    s = s .. " https://doi.org/" .. e.fields.doi
  elseif e.fields.url then
    s = s .. " " .. e.fields.url
  end
  return s
end

function M.apa.render_bibliography(bib_index, used_keys, ctx)
  ctx = ctx or {}
  local sfx_map = year_suffixes(ctx, bib_index)
  local entries = {}
  for _, k in ipairs(used_keys) do
    local e = bib_index[k]
    if e then
      entries[#entries + 1] = e
    end
  end
  table.sort(entries, function(a, b)
    return alpha_key(a, sfx_map) < alpha_key(b, sfx_map)
  end)
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = apa_format_entry(e, ctx, bib_index)
  end
  return out
end

-- Chicago author-date

M.chicago = {}

function M.chicago.render_cite(parsed, bib_index, ctx)
  ctx = ctx or {}
  local refs = {}
  for _, r in ipairs(parsed.refs or {}) do
    local entry = bib_index[r.key]
    local body
    if entry then
      local year = disambiguated_year(ctx, bib_index, r.key)
      if parsed.style == "noauthor" or parsed.style == "year" then
        body = year
      elseif parsed.style == "author" then
        body = authors_short_chicago(entry.author)
      else
        body = authors_short_chicago(entry.author) .. (year ~= "" and " " .. year or "")
      end
    else
      body = r.key
    end
    if r.prefix and r.prefix ~= "" then
      body = r.prefix .. " " .. body
    end
    if r.suffix and r.suffix ~= "" then
      body = body .. ", " .. r.suffix
    end
    refs[#refs + 1] = body
  end
  if parsed.style == "author" then
    return table.concat(refs, "; ")
  end
  return "(" .. table.concat(refs, "; ") .. ")"
end

local function chicago_format_entry(e, ctx, bib_index)
  local s = authors_full_chicago(e.author) .. "."
  local year = disambiguated_year_str(ctx, bib_index, e)
  if year then
    s = s .. " " .. year .. "."
  end
  if e.fields.title then
    s = s .. ' "' .. e.fields.title .. '."'
  end
  if e.fields.journal then
    s = s .. " " .. italic(e.fields.journal)
    if e.fields.volume then
      s = s .. " " .. e.fields.volume
    end
    if e.fields.number then
      s = s .. "(" .. e.fields.number .. ")"
    end
    if e.fields.pages then
      s = s .. ": " .. en_dash_pages(e.fields.pages)
    end
    s = s .. "."
  elseif e.type == "inproceedings" or e.type == "incollection" or e.type == "inbook" then
    if e.fields.booktitle then
      s = s .. " In " .. italic(e.fields.booktitle)
      if e.fields.pages then
        s = s .. ", " .. en_dash_pages(e.fields.pages)
      end
      s = s .. "."
    end
    if e.fields.address and e.fields.publisher then
      s = s .. " " .. e.fields.address .. ": " .. e.fields.publisher .. "."
    elseif e.fields.publisher then
      s = s .. " " .. e.fields.publisher .. "."
    end
  elseif e.fields.publisher then
    if e.fields.address then
      s = s .. " " .. e.fields.address .. ": " .. e.fields.publisher .. "."
    else
      s = s .. " " .. e.fields.publisher .. "."
    end
  end
  if e.fields.doi then
    s = s .. " https://doi.org/" .. e.fields.doi
  end
  return s
end

function M.chicago.render_bibliography(bib_index, used_keys, ctx)
  ctx = ctx or {}
  local sfx_map = year_suffixes(ctx, bib_index)
  local entries = {}
  for _, k in ipairs(used_keys) do
    local e = bib_index[k]
    if e then
      entries[#entries + 1] = e
    end
  end
  table.sort(entries, function(a, b)
    return alpha_key(a, sfx_map) < alpha_key(b, sfx_map)
  end)
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = chicago_format_entry(e, ctx, bib_index)
  end
  return out
end

-- IEEE numeric

M.ieee = {}

function M.ieee.render_cite(parsed, bib_index, ctx)
  ctx.ieee_numbers = ctx.ieee_numbers or {}
  ctx.ieee_order = ctx.ieee_order or {}
  local nums = {}
  for _, r in ipairs(parsed.refs or {}) do
    local n = ctx.ieee_numbers[r.key]
    if not n then
      n = #ctx.ieee_order + 1
      ctx.ieee_numbers[r.key] = n
      ctx.ieee_order[#ctx.ieee_order + 1] = r.key
    end
    -- Locator-style suffix attaches inside the bracket: "[1, p. 5]".
    local body = tostring(n)
    if r.suffix and r.suffix ~= "" then
      body = body .. ", " .. r.suffix
    end
    nums[#nums + 1] = body
  end
  return "[" .. table.concat(nums, ", ") .. "]"
end

local function ieee_format_entry(e, i)
  local s = "[" .. i .. "] " .. authors_full_ieee(e.author)
  if e.fields.title then
    s = s .. ', "' .. e.fields.title .. ',"'
  end
  if e.fields.journal then
    s = s .. " " .. italic(e.fields.journal)
    if e.fields.volume then
      s = s .. ", vol. " .. e.fields.volume
    end
    if e.fields.number then
      s = s .. ", no. " .. e.fields.number
    end
    if e.fields.pages then
      s = s .. ", pp. " .. en_dash_pages(e.fields.pages)
    end
  elseif e.type == "inproceedings" or e.type == "incollection" then
    if e.fields.booktitle then
      s = s .. " in " .. italic(e.fields.booktitle)
    end
    if e.fields.pages then
      s = s .. ", pp. " .. en_dash_pages(e.fields.pages)
    end
    if e.fields.publisher then
      s = s .. ", " .. e.fields.publisher
    end
  elseif e.fields.publisher then
    s = s .. ", " .. e.fields.publisher
  end
  if e.year then
    s = s .. ", " .. e.year
  end
  s = s .. "."
  return s
end

function M.ieee.render_bibliography(bib_index, used_keys, ctx)
  -- IEEE uses occurrence order (the order we hand back from
  -- render_cite). If render_bibliography is invoked without ctx
  -- having seen any cites, fall back to used_keys order.
  local order = (ctx and ctx.ieee_order) or used_keys
  local out = {}
  for i, key in ipairs(order) do
    local e = bib_index[key]
    if e then
      out[#out + 1] = ieee_format_entry(e, i)
    end
  end
  return out
end

return M
