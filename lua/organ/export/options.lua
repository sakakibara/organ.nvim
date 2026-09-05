-- Export options: `#+OPTIONS:` toggles and the in-buffer keywords that
-- feed them, resolved against Emacs's `org-export-options-alist`
-- defaults.  One table, shared by every backend, produced by
-- `from_org.from_lines` and hung off the document node as `doc.options`.
--
-- Field names mirror the ox.el property they come from, minus the colon
-- and with dashes turned into underscores (`:with-sub-superscript` ->
-- `with_sub_superscript`), so a reader can check the reference directly.
--
-- Values follow Emacs, so several are not plain booleans:
--   with_sub_superscript   true | false | "{}"
--   with_latex             true | false | "verbatim"
--   with_archived_trees    true | false | "headline"
--   with_tasks             true | false | "todo" | "done" | string[]
--   with_drawers           true | false | string[] | { ["not"] = string[] }
--   with_timestamps        true | false | "active" | "inactive"
--   with_properties        true | false | string[]
--   headline_levels        integer

local M = {}

-- `#+OPTIONS:` item -> field name.  Straight from org-export-options-alist.
local ITEMS = {
  ["H"] = "headline_levels",
  ["\\n"] = "preserve_breaks",
  ["num"] = "with_section_numbers",
  ["timestamp"] = "time_stamp_file",
  ["arch"] = "with_archived_trees",
  ["author"] = "with_author",
  ["broken-links"] = "with_broken_links",
  ["c"] = "with_clocks",
  ["creator"] = "with_creator",
  ["date"] = "with_date",
  ["d"] = "with_drawers",
  ["email"] = "with_email",
  ["*"] = "with_emphasize",
  ["e"] = "with_entities",
  [":"] = "with_fixed_width",
  ["f"] = "with_footnotes",
  ["inline"] = "with_inlinetasks",
  ["tex"] = "with_latex",
  ["p"] = "with_planning",
  ["pri"] = "with_priority",
  ["prop"] = "with_properties",
  ["'"] = "with_smart_quotes",
  ["-"] = "with_special_strings",
  ["stat"] = "with_statistics_cookies",
  ["^"] = "with_sub_superscript",
  ["toc"] = "with_toc",
  ["|"] = "with_tables",
  ["tags"] = "with_tags",
  ["tasks"] = "with_tasks",
  ["<"] = "with_timestamps",
  ["title"] = "with_title",
  ["todo"] = "with_todo_keywords",
  ["expand-links"] = "expand_links",
}

function M.defaults()
  return {
    headline_levels = 3,
    preserve_breaks = false,
    with_section_numbers = true,
    time_stamp_file = true,
    with_archived_trees = "headline",
    with_author = true,
    with_broken_links = false,
    with_clocks = false,
    with_creator = false,
    with_date = true,
    with_drawers = { ["not"] = { "LOGBOOK" } },
    with_email = false,
    with_emphasize = true,
    with_entities = true,
    with_fixed_width = true,
    with_footnotes = true,
    with_inlinetasks = true,
    with_latex = true,
    with_planning = false,
    with_priority = false,
    with_properties = false,
    with_smart_quotes = false,
    with_special_strings = true,
    with_statistics_cookies = true,
    with_sub_superscript = true,
    with_toc = true,
    with_tables = true,
    with_tags = true,
    with_tasks = true,
    with_timestamps = true,
    with_title = true,
    with_todo_keywords = true,
    expand_links = true,
    exclude_tags = { "noexport" },
    select_tags = { "export" },
    filetags = {},
  }
end

-- Read one `#+OPTIONS:` value the way `org-export--parse-option-keyword`
-- does: the text after `item:` is handed to the Lisp reader.  Recognise
-- the forms org actually documents for these options and fall back to
-- the verbatim token, which a consumer can still compare against.
local function read_value(s)
  if s == "nil" then
    return false
  elseif s == "t" then
    return true
  elseif s:match("^%-?%d+$") then
    return tonumber(s)
  elseif s == "{}" then
    return "{}"
  end
  local list = s:match("^%((.*)%)$")
  if list then
    -- `(not "LOGBOOK")` / `("a" "b")` -- the only list shapes org's own
    -- documentation gives for an OPTIONS item.
    local negated = list:match("^not%s+(.*)$")
    local items = {}
    for word in (negated or list):gmatch('"([^"]*)"') do
      items[#items + 1] = word
    end
    if negated then
      return { ["not"] = items }
    end
    return items
  end
  return s
end

-- Split an `#+OPTIONS:` line into item/value pairs.  Values are read as
-- balanced tokens so `d:(not "LOGBOOK")` stays in one piece.
local function split_options(line)
  local out = {}
  local i = 1
  local n = #line
  while i <= n do
    local s, e, item = line:find("([^%s:]+):", i)
    if not s then
      break
    end
    i = e + 1
    local value
    if line:sub(i, i) == "(" then
      local depth, j = 0, i
      while j <= n do
        local ch = line:sub(j, j)
        if ch == "(" then
          depth = depth + 1
        elseif ch == ")" then
          depth = depth - 1
          if depth == 0 then
            break
          end
        end
        j = j + 1
      end
      value = line:sub(i, j)
      i = j + 1
    else
      local j = line:find("%s", i) or (n + 1)
      value = line:sub(i, j - 1)
      i = j
    end
    if value ~= "" then
      out[#out + 1] = { item = item, value = value }
    end
  end
  return out
end

local function split_words(s, into)
  for word in s:gmatch("%S+") do
    into[#into + 1] = word
  end
end

-- Scan source lines for the export keywords and `#+OPTIONS:` toggles.
-- `overrides` is merged last so a caller can force a setting.
function M.parse(src, overrides)
  local o = M.defaults()
  local seen_exclude, seen_select = false, false
  -- A keyword inside a block is block content, not a setting: Emacs reads
  -- these through org-element, which never looks inside one.
  local open_block
  for _, line in ipairs(src or {}) do
    local begin_name = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_([%w_]+)")
    local end_name = line:match("^%s*#%+[Ee][Nn][Dd]_([%w_]+)")
    if not open_block and begin_name then
      open_block = begin_name:lower()
    elseif open_block and end_name and end_name:lower() == open_block then
      open_block = nil
    end
    local key, value = line:match("^%s*#%+([%w_-]+):%s*(.-)%s*$")
    if open_block then
      key = nil
    end
    if key then
      key = key:upper()
      if key == "OPTIONS" then
        for _, pair in ipairs(split_options(value)) do
          local field = ITEMS[pair.item]
          if field then
            o[field] = read_value(pair.value)
          end
        end
      elseif key == "EXCLUDE_TAGS" then
        if not seen_exclude then
          o.exclude_tags, seen_exclude = {}, true
        end
        split_words(value, o.exclude_tags)
      elseif key == "SELECT_TAGS" then
        if not seen_select then
          o.select_tags, seen_select = {}, true
        end
        split_words(value, o.select_tags)
      elseif key == "FILETAGS" then
        for tag in value:gmatch("[^:%s]+") do
          o.filetags[#o.filetags + 1] = tag
        end
      elseif key == "TITLE" or key == "AUTHOR" or key == "DATE" then
        local field = key:lower()
        o[field] = o[field] and (o[field] .. " " .. value) or value
      elseif key == "EMAIL" or key == "LANGUAGE" or key == "CREATOR" then
        o[key:lower()] = value
      end
    end
  end
  for k, v in pairs(overrides or {}) do
    o[k] = v
  end
  return o
end

return M
