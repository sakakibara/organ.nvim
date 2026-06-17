-- lua/organ/archive.lua
-- Implements :Org archive subtree — moves the subtree at (or containing) `line`
-- into the archive file, matching Emacs's org-archive-subtree (C-c $).

local M = {}

local obuf = require("organ.buf")
-- Helpers

local structure = require("organ.structure")

-- Parse the headline text to extract the TODO keyword and bare title.
-- Returns (todo_keyword_or_nil, bare_title).
-- headline.title_text may look like "TODO Fix the thing :tag:" — we just want
-- the first word if it's a known keyword.
local function split_todo(title_text, todo_sequence)
  if not title_text or title_text == "" then
    return nil, title_text
  end
  local first_word, rest = title_text:match("^(%S+)%s*(.-)%s*$")
  if not first_word then
    return nil, title_text
  end
  if not todo_sequence then
    return nil, title_text
  end
  for _, kw in ipairs(todo_sequence) do
    if kw ~= "|" and kw == first_word then
      return kw, rest
    end
  end
  return nil, title_text
end

-- Extract the trailing `:tag1:tag2:` tag block from a headline title,
-- returning a list of tag strings (or empty list if no tag block).
local function tags_from_title(title)
  local tag_str = title and title:match("(:[%w_@#%%:]+:)%s*$")
  local tags = {}
  if not tag_str then
    return tags
  end
  for tok in tag_str:gmatch(":([^:]+)") do
    if tok ~= "" then
      tags[#tags + 1] = tok
    end
  end
  return tags
end

-- Compute parent-chain path like "GrandParent/Parent" AND, while we
-- walk, collect each parent's tags (deepest -> shallowest).  Returns
-- (olpath_string, parent_tags_list).  parent_tags_list is ordered
-- from immediate parent outward and deduplicated.
local function parent_chain_and_tags(bufnr, headline)
  local parts = {}
  local tags, seen = {}, {}
  local target_level = headline.level - 1
  local scan_from = headline.line - 1
  while target_level >= 1 and scan_from >= 1 do
    for i = scan_from, 1, -1 do
      local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
      local stars, rest = txt:match("^(%*+)%s+(.-)%s*$")
      if stars and #stars == target_level then
        local tag_str = rest:match("(:[%w_@#%%:]+:)%s*$")
        -- Title without the tag block, for olpath display.
        local title = rest
        if tag_str then
          title = rest:sub(1, rest:find(tag_str, 1, true) - 1):match("^(.-)%s*$") or rest
        end
        table.insert(parts, 1, title)
        for _, t in ipairs(tags_from_title(rest)) do
          if not seen[t] then
            seen[t] = true
            tags[#tags + 1] = t
          end
        end
        scan_from = i - 1
        target_level = target_level - 1
        break
      elseif stars and #stars < target_level then
        scan_from = 0
        break
      end
    end
    if scan_from == 0 then
      break
    end
  end
  return table.concat(parts, "/"), tags
end

-- Back-compat wrapper.  Older code only needed the olpath string.
local function parent_chain(bufnr, headline)
  local olpath, _ = parent_chain_and_tags(bufnr, headline)
  return olpath
end

-- Read `#+FILETAGS:` directives from the top of a buffer (scans
-- first 50 lines, matching the buffer-startup scan).  Mirrors
-- `indexer.parse_filetags_value`: tokens are separated by colons OR
-- whitespace (`:tag1:tag2:` and `tag1 tag2` both work).
local function buffer_filetags(bufnr)
  local out, seen = {}, {}
  local lines =
    vim.api.nvim_buf_get_lines(bufnr, 0, math.min(50, vim.api.nvim_buf_line_count(bufnr)), false)
  for _, l in ipairs(lines) do
    local val = l:match("^%s*#%+[Ff][Ii][Ll][Ee][Tt][Aa][Gg][Ss]:%s*(.-)%s*$")
    if val then
      for tok in val:gmatch("[^:%s]+") do
        if not seen[tok] then
          seen[tok] = true
          out[#out + 1] = tok
        end
      end
    end
  end
  return out
end

-- Inherited tags for a headline (Emacs `org-get-tags` with inherit-only):
-- parent headlines' tags (deepest first) UNION `#+FILETAGS:`, in walk
-- order, deduplicated.  Direct tags on the headline being archived
-- are NOT included -- they travel with the headline title and aren't
-- "inherited" in Emacs's sense.
local function inherited_tags(bufnr, headline)
  local _, parent_tags = parent_chain_and_tags(bufnr, headline)
  local file_tags = buffer_filetags(bufnr)
  local out, seen = {}, {}
  for _, t in ipairs(parent_tags) do
    if not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  for _, t in ipairs(file_tags) do
    if not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  return out
end

-- Format an absolute path with `~` prefix when it sits under $HOME.
-- Matches Emacs `abbreviate-file-name`, which is what
-- `org-archive-save-context-info` writes for ARCHIVE_FILE and the
-- source-header comment.
local function abbreviate_path(path)
  return vim.fn.fnamemodify(path, ":~")
end

-- Format a timestamp for ARCHIVE_TIME.  Emacs uses the inactive
-- timestamp format WITHOUT the `[ ]` brackets (per
-- `(substring (cdr org-time-stamp-formats) 1 -1)`), so just the
-- bare `YYYY-MM-DD Dow HH:MM` body.
local function format_archive_time(ts)
  return os.date("%Y-%m-%d %a %H:%M", ts)
end

-- Parse an Emacs `org-archive-location` string into (file_template,
-- headline_title).  Format: `"FILE::HEADLINE"`, either part optional.
--   `"%s_archive::"`              -> ("%s_archive", "")
--   `"%s_archive::* Archive"`     -> ("%s_archive", "Archive")
--   `"::* Archive"`               -> ("", "Archive")  (same file as source)
--   `"~/.org/%s_archive::Old"`    -> ("~/.org/%s_archive", "Old")
-- HEADLINE may be written with or without the leading `* ` (Emacs
-- accepts both); we normalise to the bare title here so callers
-- don't need to strip stars.
local function parse_location(location_str)
  local file_part, headline_part = location_str:match("^(.-)::(.*)$")
  if not file_part then
    file_part = location_str
    headline_part = ""
  end
  headline_part = (headline_part or ""):gsub("^%s*%*+%s*", "")
  headline_part = headline_part:gsub("^%s+", ""):gsub("%s+$", "")
  return file_part, headline_part
end

-- Resolve a parsed (file_template, headline) pair against the source
-- file path.  Substitutes `%s` with the source's basename-stem (so
-- `"%s_archive"` becomes `"<stem>_archive.org"`), expands `~`, and
-- resolves relative paths against the source's directory.  Returns
-- the absolute archive file path.
local function resolve_archive_path(file_template, src_path)
  local fp = file_template
  if fp == "" then
    -- Empty file part -> same file as source.
    return src_path
  end
  -- %s substitution -- replace with the source file's basename (Emacs
  -- does the same; `"%s_archive"` -> `"todo.org_archive"` not the
  -- whole path).
  if fp:find("%%s", 1, false) then
    local src_basename = vim.fn.fnamemodify(src_path, ":t")
    fp = fp:gsub("%%s", src_basename)
  end
  fp = vim.fn.expand(fp) -- expand `~`
  if not fp:match("^/") then
    -- Relative -> resolve against the source's directory.
    fp = vim.fn.fnamemodify(src_path, ":h") .. "/" .. fp
  end
  return vim.fn.fnamemodify(fp, ":p")
end

-- Look for an `:ARCHIVE:` property on the subtree being archived.
-- The property drawer sits between the headline line and the first
-- body line; scan only that range.  Returns the property value
-- string (an archive-location spec) or nil.
local function subtree_archive_property(bufnr, headline)
  local scan_start = headline.line + 1
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  -- Skip planning lines (SCHEDULED/DEADLINE/CLOSED) until the
  -- drawer or first body line.
  local i = scan_start
  while i <= last_line do
    local l = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") or l:match("^%s*CLOSED:") then
      i = i + 1
    else
      break
    end
  end
  if i > last_line then
    return nil
  end
  local opener = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
  if not opener:match("^%s*:PROPERTIES:%s*$") then
    return nil
  end
  for j = i + 1, last_line do
    local l = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    if l:match("^%s*:END:%s*$") then
      return nil
    end
    local val = l:match("^%s*:[Aa][Rr][Cc][Hh][Ii][Vv][Ee]:%s*(.-)%s*$")
    if val and val ~= "" then
      return val
    end
  end
  return nil
end

-- Look for a `#+ARCHIVE:` directive in the buffer top (first 50
-- lines).  Returns the directive value or nil.
local function buffer_archive_directive(bufnr)
  local lines =
    vim.api.nvim_buf_get_lines(bufnr, 0, math.min(50, vim.api.nvim_buf_line_count(bufnr)), false)
  for _, l in ipairs(lines) do
    local val = l:match("^%s*#%+[Aa][Rr][Cc][Hh][Ii][Vv][Ee]:%s*(.-)%s*$")
    if val and val ~= "" then
      return val
    end
  end
  return nil
end

-- Resolve the archive destination for this headline: (archive_path,
-- headline_title_or_nil).  Precedence (highest -> lowest):
--   1. `:ARCHIVE:` property on the subtree being archived
--   2. `#+ARCHIVE:` directive at the buffer top
--   3. `cfg.location` -- string OR function(src_path)->string
-- Mirrors Emacs `org-archive--compute-location`, with the
-- function-form `cfg.location` an organ extension for dynamic
-- destinations (Emacs's `org-archive-location` is string-only).
-- A nil headline title means "no wrapper heading -- append at the
-- archive file's top level" (Emacs default for `"%s_archive::"`).
local function resolve_archive_destination(bufnr, headline, cfg, src_path)
  local location_str = subtree_archive_property(bufnr, headline) or buffer_archive_directive(bufnr)
  if not location_str then
    local loc = cfg.location
    if type(loc) == "function" then
      location_str = loc(src_path)
    else
      location_str = loc
    end
  end
  if not location_str or location_str == "" then
    -- No location configured anywhere.  Fall back to the Emacs
    -- default so archive isn't a hard error on a stripped config.
    location_str = "%s_archive::"
  end
  local fp_template, hdline = parse_location(location_str)
  local archive_path = resolve_archive_path(fp_template, src_path)
  if hdline == "" then
    return archive_path, nil
  end
  return archive_path, hdline
end

-- Ensure the file exists, creating parent dirs as needed.
local function ensure_file(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  if not vim.loop.fs_stat(path) then
    vim.fn.writefile({}, path)
  end
end

-- Read file lines (returns {} if missing).
local function read_file_lines(path)
  if not vim.loop.fs_stat(path) then
    return {}
  end
  return vim.fn.readfile(path)
end

-- Find (1-based) the line of the given top-level headline title in lines.
-- Returns nil if not found.
local function find_top_headline(lines, title)
  for i, l in ipairs(lines) do
    local stars, t = l:match("^(%*+)%s+(.-)%s*$")
    if stars and #stars == 1 and t == title then
      return i
    end
  end
  return nil
end

-- Re-level a list of lines so the top headline goes from src_level to
-- dst_level (all nested headlines shift by the same delta).
local function relevel_lines(lines, src_level, dst_level)
  local delta = dst_level - src_level
  if delta == 0 then
    return lines
  end
  local out = {}
  for _, l in ipairs(lines) do
    local stars = l:match("^(%*+)")
    if stars then
      local new_level = math.max(1, #stars + delta)
      out[#out + 1] = string.rep("*", new_level) .. l:sub(#stars + 1)
    else
      out[#out + 1] = l
    end
  end
  return out
end

-- Insert a :PROPERTIES: drawer (or append to existing one) with the given
-- key/value pairs into `lines` right after line 1 (the headline line).
-- `pairs_list` is a list of { key, value } tables (ordered).
-- Returns the modified lines table.
local function inject_properties(lines, pairs_list)
  if #pairs_list == 0 then
    return lines
  end

  -- Find whether there's an existing :PROPERTIES: drawer already.
  -- It must start right after the headline (line index 2 = lines[2]).
  local insert_before_end = nil -- 1-based index of :END: line
  local drawer_start = nil

  -- Skip planning lines (SCHEDULED/DEADLINE/CLOSED) before looking for drawer.
  local scan = 2
  while scan <= #lines do
    local l = lines[scan]
    if l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") or l:match("^%s*CLOSED:") then
      scan = scan + 1
    else
      break
    end
  end

  if scan <= #lines and lines[scan]:match("^%s*:PROPERTIES:%s*$") then
    drawer_start = scan
    for i = scan + 1, #lines do
      if lines[i]:match("^%s*:END:%s*$") then
        insert_before_end = i
        break
      end
    end
  end

  local prop_lines = {}
  for _, kv in ipairs(pairs_list) do
    prop_lines[#prop_lines + 1] = ":" .. kv[1] .. ": " .. kv[2]
  end

  if insert_before_end then
    -- Inject before :END: (insert_before_end - 1 is the last prop line idx)
    local out = {}
    for i = 1, insert_before_end - 1 do
      out[#out + 1] = lines[i]
    end
    for _, pl in ipairs(prop_lines) do
      out[#out + 1] = pl
    end
    for i = insert_before_end, #lines do
      out[#out + 1] = lines[i]
    end
    return out
  else
    -- No existing drawer: insert after line 1 (the headline).
    local out = { lines[1] }
    out[#out + 1] = ":PROPERTIES:"
    for _, pl in ipairs(prop_lines) do
      out[#out + 1] = pl
    end
    out[#out + 1] = ":END:"
    for i = 2, #lines do
      out[#out + 1] = lines[i]
    end
    return out
  end
end

-- Public API

--- Archive the subtree containing `line` in `bufnr` to the configured archive
--- file.  Both `bufnr` and `line` default to the current buffer + cursor.
--- @param opts? { bufnr?: number, line?: number }
--- @return string|nil err  nil on success, error string on failure.
--- @return string|nil archive_path  Absolute path written to (on success).
function M.archive_subtree(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")

  local cfg = require("organ.buf_config").read(bufnr, "archive") or {}
  if cfg.enabled == false then
    return "archive feature is disabled"
  end

  -- 1. Find containing headline.
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "no headline at or above cursor"
  end

  -- 2. Compute subtree end.
  local subtree_end = structure._subtree_end(bufnr, hl)

  -- 3. Source file path.
  local src_path = vim.api.nvim_buf_get_name(bufnr)
  if src_path == "" then
    return "buffer has no file path"
  end
  src_path = vim.fn.fnamemodify(src_path, ":p") -- expand to absolute

  -- 4. Resolve archive destination from (in order): subtree
  --    `:ARCHIVE:` property, buffer `#+ARCHIVE:` directive, config
  --    `location`, legacy `file_pattern + headline`.
  local archive_path, archive_hl_title = resolve_archive_destination(bufnr, hl, cfg, src_path)

  -- 6. Read subtree lines from source buffer.
  local subtree_lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, subtree_end, false)
  if #subtree_lines == 0 then
    return "subtree is empty"
  end

  -- 7. Collect metadata.
  local now_ts = os.time()
  local archive_time = format_archive_time(now_ts)

  local olpath = parent_chain(bufnr, hl)

  -- Extract TODO keyword from headline title for ARCHIVE_TODO.
  local todo_seq = require("organ.todo").all_keywords()
  local todo_kw, bare_title = split_todo(hl.title_text, todo_seq)

  -- 8. Open (or create) the archive file.
  ensure_file(archive_path)
  local arc_lines = read_file_lines(archive_path)

  -- 8a. Source-file header comment.  Emacs's `org-archive--add-
  --     comment` writes `# Archived entries from file <path>` once,
  --     when the archive file is empty (newly created).  Default ON
  --     for Emacs parity; opt out via `cfg.write_source_header =
  --     false`.
  local is_empty = (#arc_lines == 0) or (#arc_lines == 1 and arc_lines[1] == "")
  if is_empty and cfg.write_source_header ~= false then
    arc_lines = {
      "# Archived entries from file " .. abbreviate_path(src_path),
      "",
    }
  end

  -- Find or create the archive wrapper headline (when one is
  -- configured).  `archive_hl_title == nil` means "no wrapper" --
  -- the location syntax `"%s_archive::"` (empty headline part)
  -- triggers this and the subtree is appended at the file's top
  -- level instead.
  local arc_hl_line, dst_level
  if archive_hl_title then
    arc_hl_line = find_top_headline(arc_lines, archive_hl_title)
    if not arc_hl_line then
      arc_lines[#arc_lines + 1] = "* " .. archive_hl_title
      arc_hl_line = #arc_lines
    end
    dst_level = 2 -- child of the level-1 wrapper headline
  else
    arc_hl_line = #arc_lines -- append at end
    dst_level = 1 -- top-level in the archive file
  end

  local releveled = relevel_lines(subtree_lines, hl.level, dst_level)

  -- 9. Inject metadata into the moved subtree's top headline (releveled[1]).
  -- `add_metadata = true/false` is a coarse on/off; `save_context_info`
  -- (Emacs `org-archive-save-context-info`, default
  -- `{"time","file","olpath","category","todo","itags"}`) chooses
  -- WHICH context properties to inject.  Defaults match Emacs.
  local add_meta = cfg.add_metadata
  if add_meta == nil then
    add_meta = true
  end
  local context_set
  if cfg.save_context_info ~= nil then
    context_set = {}
    for _, k in ipairs(cfg.save_context_info) do
      context_set[k] = true
    end
  else
    context_set = {
      time = true,
      file = true,
      olpath = true,
      category = true,
      todo = true,
      itags = true,
    }
  end

  if add_meta then
    local props = {}
    if context_set.time then
      props[#props + 1] = { "ARCHIVE_TIME", archive_time }
    end
    if context_set.file then
      -- Emacs writes ARCHIVE_FILE through `abbreviate-file-name`, so
      -- `/Users/sho/...` becomes `~/...`.  Plain absolute would also
      -- work but breaks portability across machines with different
      -- home dirs.
      props[#props + 1] = { "ARCHIVE_FILE", abbreviate_path(src_path) }
    end
    if context_set.olpath and olpath ~= "" then
      props[#props + 1] = { "ARCHIVE_OLPATH", olpath }
    end
    if context_set.todo and todo_kw then
      props[#props + 1] = { "ARCHIVE_TODO", todo_kw }
    end
    if context_set.category then
      local cat = require("organ.agenda")
      -- File category resolution is private to agenda; do a cheap
      -- file-basename fallback so we always emit ARCHIVE_CATEGORY
      -- when `category` is in the set.
      local base = src_path:match("([^/]+)%.org$") or src_path:match("([^/]+)$") or ""
      local _ = cat
      if base ~= "" then
        props[#props + 1] = { "ARCHIVE_CATEGORY", base }
      end
    end
    if context_set.itags then
      -- Inherited tags = ancestor headlines' tags + `#+FILETAGS`.
      -- Direct tags on the moved headline travel with its title and
      -- aren't part of ARCHIVE_ITAGS (Emacs `org-get-tags` with
      -- inherit-only behavior).
      local itags = inherited_tags(bufnr, hl)
      if #itags > 0 then
        -- Emacs `org-archive-subtree` writes ARCHIVE_ITAGS as a
        -- space-joined list (`mapconcat 'identity ... " "`), not
        -- the colon-wrapped tag-block syntax.
        props[#props + 1] = { "ARCHIVE_ITAGS", table.concat(itags, " ") }
      end
    end
    releveled = inject_properties(releveled, props)
  end

  -- If there was a TODO keyword, strip it from the moved headline's first line
  -- so it doesn't pollute archive agenda.
  if todo_kw and add_meta then
    local first = releveled[1]
    -- Replace "* TODO <rest>" with "* <bare_title>" (bare_title already stripped)
    local stars_part = first:match("^(%*+%s+)")
    if stars_part then
      releveled[1] = stars_part .. bare_title
    end
  end

  -- 10. Insert the releveled subtree right after the archive headline (append
  --     to its section, i.e. at the end of the file if Archive is the last hl).
  -- Find the end of the archive headline's section (where to insert).
  -- We walk forward from arc_hl_line+1 looking for a sibling or parent headline.
  local insert_at = #arc_lines + 1 -- default: append at end
  do
    local arc_lvl = 1 -- "* Archive" is level 1
    for i = arc_hl_line + 1, #arc_lines do
      local l = arc_lines[i]
      local stars = l:match("^(%*+)%s")
      if stars and #stars <= arc_lvl then
        insert_at = i
        break
      end
    end
  end

  -- Build new archive file content.
  local new_arc = {}
  for i = 1, insert_at - 1 do
    new_arc[#new_arc + 1] = arc_lines[i]
  end
  for _, l in ipairs(releveled) do
    new_arc[#new_arc + 1] = l
  end
  for i = insert_at, #arc_lines do
    new_arc[#new_arc + 1] = arc_lines[i]
  end

  -- 11. Write archive file (atomic — a crash mid-write would otherwise
  -- corrupt the user's archive).
  local ok, err =
    require("organ.path").write_atomic(archive_path, table.concat(new_arc, "\n") .. "\n")
  if not ok then
    return "failed to write archive file: " .. tostring(err)
  end

  -- 12. Delete original subtree from source buffer.
  obuf.set_lines(bufnr, hl.line - 1, subtree_end, {})

  -- 12a. Tidy the deletion site so leftover blank-line stragglers
  -- collapse to whatever pattern the surviving buffer uses.
  pcall(function()
    require("organ.spacing").normalize_at_cut(bufnr, hl.line)
  end)

  -- 13. Save source buffer.
  local cur = vim.api.nvim_get_current_buf()
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(bufnr)
  end
  vim.cmd("silent! write")
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(cur)
  end

  return nil, archive_path
end

-- Archive to a sibling `* Archive` headline within the SAME buffer (Emacs
-- C-c C-x A). Reuses the metadata-injection + relevel helpers above.
--- Archive the subtree at cursor under a sibling `* Archive` headline in the
--- SAME buffer (Emacs `C-c C-x A`).  Both `bufnr` and `line` default to the
--- current buffer + cursor.
--- @param opts? { bufnr?: number, line?: number }
--- @return string|nil err  nil on success, error string on failure.
function M.archive_to_sibling(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local cfg = require("organ.buf_config").read(bufnr, "archive") or {}
  if cfg.enabled == false then
    return "archive feature is disabled"
  end

  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "no headline at or above cursor"
  end
  local subtree_end = structure._subtree_end(bufnr, hl)
  local subtree_lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, subtree_end, false)
  if #subtree_lines == 0 then
    return "subtree is empty"
  end

  local archive_hl_title = cfg.sibling_heading or "Archive"
  local now_ts = os.time()
  local archive_time = format_archive_time(now_ts)

  local olpath = parent_chain(bufnr, hl)
  local todo_seq = require("organ.todo").all_keywords()
  local todo_kw, bare_title = split_todo(hl.title_text, todo_seq)

  -- Read entire buffer to operate in memory.
  local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Locate or create the top-level Archive headline.
  local arc_hl_line = find_top_headline(all, archive_hl_title)
  local appended = false
  if not arc_hl_line then
    -- Append at end with a leading blank-line separator.
    if all[#all] and all[#all] ~= "" then
      all[#all + 1] = ""
    end
    all[#all + 1] = "* " .. archive_hl_title
    arc_hl_line = #all
    appended = true
  end

  -- Re-level the subtree: top becomes level 2 under "* Archive".
  local releveled = relevel_lines(subtree_lines, hl.level, 2)

  local add_meta = cfg.add_metadata
  if add_meta == nil then
    add_meta = true
  end
  if add_meta then
    -- Same `save_context_info` token set as archive_subtree.  ITAGS
    -- (inherited tags) IS relevant for sibling archive too even
    -- though the file doesn't change -- the archived headline loses
    -- its olpath, so the tags it WOULD have inherited from its
    -- former parents need to travel with it.  FILE / CATEGORY are
    -- omitted because the destination is the same buffer.
    local context_set
    if cfg.save_context_info ~= nil then
      context_set = {}
      for _, k in ipairs(cfg.save_context_info) do
        context_set[k] = true
      end
    else
      context_set = { time = true, olpath = true, todo = true, itags = true }
    end
    local props = {}
    if context_set.time then
      props[#props + 1] = { "ARCHIVE_TIME", archive_time }
    end
    if context_set.olpath and olpath ~= "" then
      props[#props + 1] = { "ARCHIVE_OLPATH", olpath }
    end
    if context_set.todo and todo_kw then
      props[#props + 1] = { "ARCHIVE_TODO", todo_kw }
    end
    if context_set.itags then
      local itags = inherited_tags(bufnr, hl)
      if #itags > 0 then
        props[#props + 1] = { "ARCHIVE_ITAGS", table.concat(itags, " ") }
      end
    end
    releveled = inject_properties(releveled, props)
  end

  if todo_kw and add_meta then
    local stars_part = releveled[1]:match("^(%*+%s+)")
    if stars_part then
      releveled[1] = stars_part .. bare_title
    end
  end

  -- Insertion point: end of the Archive headline's section.
  local insert_at = #all + 1
  for i = arc_hl_line + 1, #all do
    local stars = (all[i] or ""):match("^(%*+)%s")
    if stars and #stars <= 1 then
      insert_at = i
      break
    end
  end

  -- Compute updated buffer: subtree removed from source, appended into Archive.
  local out = {}
  -- The Archive headline may sit before or after the source subtree; build
  -- the new buffer content respecting both cases.
  local function append_archive_block(buf)
    -- Archive block already in `all` past hl.line..subtree_end is preserved
    -- because we walk `all` once below. This helper just emits the moved
    -- subtree lines at the right spot.
    for _, l in ipairs(releveled) do
      buf[#buf + 1] = l
    end
  end

  for i, ln in ipairs(all) do
    -- Skip the source subtree.
    if i >= hl.line and i <= subtree_end then
      -- nothing
    else
      out[#out + 1] = ln
      -- After the Archive headline's section ends, splice in the moved subtree.
      if i + 1 == insert_at then
        -- We're right before the line that would terminate the archive section
        -- (a sibling/parent headline). Insert here.
        if i >= arc_hl_line then -- only after we've already passed Archive
          append_archive_block(out)
        end
      end
    end
  end
  -- If insert_at points past EOF (Archive is last and no terminating headline),
  -- the loop above never inserted; do it now.
  local appended_in_loop = false
  do
    -- Detect via reverse search: is the moved subtree's first line in `out`?
    for j = #out, 1, -1 do
      if out[j] == releveled[1] then
        appended_in_loop = true
        break
      end
    end
  end
  if not appended_in_loop then
    append_archive_block(out)
  end

  obuf.set_lines(bufnr, 0, -1, out)

  -- Tidy the cut site so leftover blank-line stragglers collapse to
  -- whatever pattern the surviving buffer uses.
  pcall(function()
    require("organ.spacing").normalize_at_cut(bufnr, hl.line)
  end)

  -- Save source buffer.
  local cur = vim.api.nvim_get_current_buf()
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(bufnr)
  end
  vim.cmd("silent! write")
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(cur)
  end

  return nil
end

local function notify_archived(arc_path)
  if require("organ.buf_config").read(nil, "notify") then
    require("organ.errors").schedule("organ.archive", function()
      require("organ.notify").info("archived to " .. (arc_path or "archive file"))
    end)
  end
end

-- Set the `:ARCHIVE:` tag on the headline at cursor without moving
-- it.  Emacs `org-archive-set-tag` / `org-toggle-archive-tag`
-- equivalent.  When the tag is already set, this is a no-op.
function M.set_archive_tag(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "no headline at or above cursor"
  end
  local tag_writer = require("organ.tag_writer")
  local current = (tag_writer.read(bufnr, hl.line) or {}).tags or {}
  for _, t in ipairs(current) do
    if t == "ARCHIVE" then
      return nil -- already tagged; no-op
    end
  end
  current[#current + 1] = "ARCHIVE"
  return tag_writer.write(bufnr, hl.line, current)
end

-- Read every property from the subtree's :PROPERTIES: drawer into a
-- lower-cased-key map.  Returns `{}` when there's no drawer (or the
-- drawer is empty).  Skips planning lines (SCHEDULED / DEADLINE /
-- CLOSED) before looking for the drawer, mirroring inject_properties.
local function extract_subtree_properties(bufnr, headline)
  local out = {}
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  local i = headline.line + 1
  while i <= last_line do
    local l = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") or l:match("^%s*CLOSED:") then
      i = i + 1
    else
      break
    end
  end
  if i > last_line then
    return out
  end
  local opener = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
  if not opener:match("^%s*:PROPERTIES:%s*$") then
    return out
  end
  for j = i + 1, last_line do
    local l = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    if l:match("^%s*:END:%s*$") then
      break
    end
    local key, val = l:match("^%s*:([%w_+]+):%s*(.-)%s*$")
    if key then
      out[key:lower()] = val
    end
  end
  return out
end

-- Strip every `ARCHIVE_*` property from the :PROPERTIES: drawer in
-- `lines` (a subtree snapshot).  If the drawer becomes empty, drop
-- the whole `:PROPERTIES:`/`:END:` block too -- a bare empty drawer
-- is noise.  Used by unarchive when restoring a subtree to its
-- source: the ARCHIVE_* set is bookkeeping that loses meaning the
-- moment the subtree is back in place.
local function strip_archive_properties(lines)
  local out = {}
  local in_drawer = false
  local kept = {}
  for _, l in ipairs(lines) do
    if not in_drawer then
      if l:match("^%s*:PROPERTIES:%s*$") then
        in_drawer = true
        kept = {}
      else
        out[#out + 1] = l
      end
    else
      if l:match("^%s*:END:%s*$") then
        in_drawer = false
        if #kept > 0 then
          out[#out + 1] = ":PROPERTIES:"
          for _, p in ipairs(kept) do
            out[#out + 1] = p
          end
          out[#out + 1] = ":END:"
        end
        kept = {}
      else
        local key = l:match("^%s*:([%w_+]+):")
        if not (key and key:upper():match("^ARCHIVE_")) then
          kept[#kept + 1] = l
        end
      end
    end
  end
  return out
end

-- Walk an `ARCHIVE_OLPATH` segment list against `dest_bufnr`'s
-- headline cache to find the parent the subtree should land under.
-- Each segment must match a heading at the corresponding depth
-- (segment 1 -> level 1, segment 2 -> level 2, ...) within the
-- subtree of the previous segment's match.  Returns the matched
-- headline `{ line, level }` or nil when the chain breaks (parent
-- moved / renamed / deleted since archive time).
local function find_parent_by_olpath(dest_bufnr, segments)
  if #segments == 0 then
    return nil
  end
  local headlines = require("organ.element_cache").headlines(dest_bufnr)
  local search_start = 1
  local search_end = vim.api.nvim_buf_line_count(dest_bufnr)
  local last_match
  for depth, seg in ipairs(segments) do
    local match
    for _, h in ipairs(headlines) do
      if h.line >= search_start and h.line <= search_end and h.level == depth then
        -- Heading title from the cache may include tags-block;
        -- strip the trailing `:tag1:tag2:` block before comparing.
        local title = (h.title or ""):gsub("(:[%w_@#%%:]+:)%s*$", ""):gsub("%s*$", "")
        if title == seg then
          match = h
          break
        end
      elseif h.line >= search_start and h.line <= search_end and h.level < depth then
        -- Walked out of the parent's subtree without finding the
        -- next segment.  Chain is broken.
        return nil
      end
    end
    if not match then
      return nil
    end
    last_match = match
    -- For the next segment, search within this heading's subtree:
    -- from the line after the match, up to (but not including) the
    -- next heading of the same-or-shallower depth.
    search_start = match.line + 1
    for _, h in ipairs(headlines) do
      if h.line > match.line and h.level <= match.level then
        search_end = h.line - 1
        break
      end
    end
  end
  return last_match and { line = last_match.line, level = last_match.level } or nil
end

-- Restore a subtree from the archive file back to its original
-- source.  Cursor must be on the archived headline (i.e. inside the
-- archive file -- mirror image of `archive_subtree`).
--
-- Reads `:ARCHIVE_FILE:` (destination) and `:ARCHIVE_OLPATH:`
-- (parent chain in the destination) off the subtree's :PROPERTIES:
-- drawer, walks the OLPATH in the destination to locate the parent,
-- strips every ARCHIVE_* property from the subtree, re-levels to fit
-- under the located parent (or to top-level when OLPATH is empty),
-- inserts at the end of the parent's section, and deletes the
-- subtree from the archive file.
--
-- Soft-fallback: if OLPATH no longer resolves (parent renamed /
-- moved / deleted), the subtree lands at the destination file's
-- top level and a notice is printed.  Hard failures (no
-- ARCHIVE_FILE property, destination unreadable) return an error
-- string.
--
-- @param opts? { bufnr?: number, line?: number }
-- @return string|nil err          nil on success, error string on failure
-- @return string|nil dest_path    absolute path written to (on success)
function M.unarchive(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")

  local cfg = require("organ.buf_config").read(bufnr, "archive") or {}
  if cfg.enabled == false then
    return "archive feature is disabled"
  end

  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "no headline at or above cursor"
  end

  local props = extract_subtree_properties(bufnr, hl)
  local dest_str = props.archive_file
  if not dest_str or dest_str == "" then
    return "no :ARCHIVE_FILE: property on this subtree -- can't unarchive without it"
  end
  local dest_path = vim.fn.fnamemodify(vim.fn.expand(dest_str), ":p")
  if not vim.loop.fs_stat(dest_path) then
    return "destination file does not exist: " .. dest_path
  end

  local subtree_end = structure._subtree_end(bufnr, hl)
  local subtree_lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, subtree_end, false)
  if #subtree_lines == 0 then
    return "subtree is empty"
  end

  local cleaned = strip_archive_properties(subtree_lines)

  -- Restore the TODO keyword that archive_subtree stripped off the
  -- headline into ARCHIVE_TODO.  Without this the round trip loses
  -- the state: `* DONE Foo` archives to `* Foo` + `:ARCHIVE_TODO:
  -- DONE`, and unarchive would otherwise drop the keyword when it
  -- strips the property.  Prepend it back onto the headline line.
  if props.archive_todo and props.archive_todo ~= "" then
    local stars, title = cleaned[1]:match("^(%*+%s+)(.*)$")
    if stars then
      cleaned[1] = stars .. props.archive_todo .. " " .. title
    end
  end

  -- Load the destination so we can use structure helpers + apply
  -- changes through buffer APIs (preserves any concurrent open
  -- buffer's view, and writes through the normal `:write` flow
  -- that fires BufWritePre/Post for plugins like indexer).
  local dest_bufnr = vim.fn.bufadd(dest_path)
  vim.fn.bufload(dest_bufnr)
  require("organ.element_cache").invalidate(dest_bufnr)

  local olpath_segments = {}
  local olpath_str = props.archive_olpath or ""
  for seg in olpath_str:gmatch("[^/]+") do
    olpath_segments[#olpath_segments + 1] = seg
  end

  local parent = find_parent_by_olpath(dest_bufnr, olpath_segments)
  local insert_at, dst_level, fell_back
  if parent then
    local parent_end = structure._subtree_end(dest_bufnr, parent)
    insert_at = parent_end + 1
    dst_level = parent.level + 1
  else
    -- No OLPATH, OR OLPATH didn't resolve -- append at file end at
    -- top level.  This is a soft fallback (not an error) so the
    -- user doesn't lose the archived content when a parent moved.
    insert_at = vim.api.nvim_buf_line_count(dest_bufnr) + 1
    dst_level = 1
    fell_back = (#olpath_segments > 0)
  end

  local releveled = relevel_lines(cleaned, hl.level, dst_level)

  vim.api.nvim_buf_set_lines(dest_bufnr, insert_at - 1, insert_at - 1, false, releveled)
  vim.api.nvim_buf_call(dest_bufnr, function()
    vim.cmd("silent! write")
  end)

  -- Delete the subtree from the archive file (current buffer).
  obuf.set_lines(bufnr, hl.line - 1, subtree_end, {})
  pcall(function()
    require("organ.spacing").normalize_at_cut(bufnr, hl.line)
  end)
  local cur = vim.api.nvim_get_current_buf()
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(bufnr)
  end
  vim.cmd("silent! write")
  if bufnr ~= cur then
    vim.api.nvim_set_current_buf(cur)
  end

  if fell_back then
    pcall(function()
      require("organ.notify").warn(
        "ARCHIVE_OLPATH `"
          .. olpath_str
          .. "` no longer resolves in "
          .. dest_path
          .. "; restored at top level"
      )
    end)
  end

  return nil, dest_path
end

-- Dispatch to the action chosen by `archive.default_command`.
function M.default(opts)
  local bufnr = (opts and opts.bufnr) or vim.api.nvim_get_current_buf()
  local cmd = (require("organ.buf_config").read(bufnr, "archive") or {}).default_command
    or "subtree"
  if cmd == "to_archive_sibling" then
    return M.archive_to_sibling(opts)
  end
  if cmd == "set_archive_tag" then
    return M.set_archive_tag(opts)
  end
  return M.archive_subtree(opts)
end

M.commands = {
  archive = {
    fn = function()
      local err, arc_path = M.default()
      if err then
        require("organ.notify").error(err)
      elseif arc_path then
        notify_archived(arc_path)
      else
        require("organ.notify").info("archived")
      end
    end,
    desc = "Archive the subtree using `archive.default_command` (Emacs C-c $)",
  },
  ["archive subtree"] = {
    fn = function()
      local err, arc_path = M.archive_subtree()
      if err then
        require("organ.notify").error(err)
      else
        notify_archived(arc_path)
      end
    end,
    desc = "Archive the subtree at cursor to the archive file",
  },
  ["archive to_sibling"] = {
    fn = function()
      local err = M.archive_to_sibling()
      if err then
        require("organ.notify").error(err)
      else
        require("organ.notify").info("subtree archived to sibling")
      end
    end,
    desc = "Archive the subtree to a sibling under an Archive heading in the same file",
  },
  ["archive set_tag"] = {
    fn = function()
      local err = M.set_archive_tag()
      if err then
        require("organ.notify").error(err)
      else
        require("organ.notify").info("archive tag set")
      end
    end,
    desc = "Toggle the :ARCHIVE: tag on the headline at cursor (no move)",
  },
  unarchive = {
    fn = function()
      local err, dest_path = M.unarchive()
      if err then
        require("organ.notify").error(err)
      else
        require("organ.notify").info("restored to " .. (dest_path or "source file"))
      end
    end,
    desc = "Restore the archived subtree at cursor to its source file (uses :ARCHIVE_FILE: / :ARCHIVE_OLPATH:)",
  },
}

return M
