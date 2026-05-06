-- lua/organ/indexer.lua
--
-- Walks the tree-sitter-org block grammar (with org_inline injection)
-- to extract heading + planning + property + drawer metadata for the
-- SQLite index.
--
-- Inline structure (links, timestamps, heading sub-fields) is provided
-- by the injected tree-sitter-org-inline grammar; this module walks
-- those subtrees natively via vim.treesitter.
--
-- Heading nesting is reconstructed via a Lua-side level-based stack
-- (see `collect_all_headings`). The grammar's `heading: ... repeat($.heading)`
-- rule is content-recursive, not level-aware — design intent per
--
local M = {}

-- Extractor-version stamp.  Stored on every `files` row alongside
-- mtime+hash so `should_skip` can invalidate the cache when our
-- extract pipeline changes underneath the user (parser binary
-- rebuilt, indexer source modified).  Without this, files indexed
-- against an older grammar stay cached forever because their disk
-- mtime hasn't changed — the user has to know about :Org scan! to
-- recover.  With it, every parser/code update triggers a transparent
-- re-extract on the next scan.
--
-- Computed from the parser binary's mtime + this file's contents +
-- the schema file's contents.  All three are things we control;
-- when any changes, the hash changes, and every row gets re-extracted.
local _extractor_version
local function extractor_version()
  if _extractor_version then
    return _extractor_version
  end
  local parts = {}
  -- Parser binary mtime (rebuild bumps this).
  local organ = require("organ")
  local pp = organ.config and organ.config.parser_path
  if pp then
    local st = vim.uv.fs_stat(pp)
    if st then
      parts[#parts + 1] = "p:" .. tostring(st.mtime.sec)
    end
  end
  -- Indexer source hash (this file).  Self-locate via debug.getinfo
  -- so it works regardless of where the plugin lives.
  local info = debug.getinfo(1, "S").source
  if info:sub(1, 1) == "@" then
    local f = io.open(info:sub(2), "r")
    if f then
      parts[#parts + 1] = "i:" .. vim.fn.sha256(f:read("*a"))
      f:close()
    end
  end
  -- Schema source hash (column defs).
  local sp = organ.config and organ.config.schema_path
  if sp then
    local f = io.open(sp, "r")
    if f then
      parts[#parts + 1] = "s:" .. vim.fn.sha256(f:read("*a"))
      f:close()
    end
  end
  _extractor_version = vim.fn.sha256(table.concat(parts, "|"))
  return _extractor_version
end
M._extractor_version = extractor_version -- exposed for tests

local DEFAULT_TODO_KEYWORDS = {
  TODO = true,
  DONE = true,
  NEXT = true,
  WAITING = true,
  CANCELLED = true,
  HOLD = true,
  PROJ = true,
}

local function parse_heading_line(line, todo_keywords)
  todo_keywords = todo_keywords or DEFAULT_TODO_KEYWORDS
  local stars, rest = line:match("^(%*+)%s+(.*)$")
  if not stars then
    return nil
  end
  local result =
    { level = #stars, todo = nil, priority = nil, title = "", tags = {}, commented = false }
  local body, tag_run = rest:match("^(.-)%s*(:[%w_@#%%]+:.*)$")
  if body and tag_run and tag_run:match("^:[%w_@#%%]+:[%w_@#%%:]*$") then
    local valid = true
    for tag in tag_run:gmatch(":([^:]+)") do
      if not tag:match("^[%w_@#%%]+$") then
        valid = false
        break
      end
    end
    if valid then
      rest = body
      for tag in tag_run:gmatch(":([%w_@#%%]+)") do
        result.tags[#result.tags + 1] = tag
      end
    end
  end
  local first_word, after_first = rest:match("^(%S+)%s*(.*)$")
  if first_word and todo_keywords[first_word] then
    result.todo = first_word
    rest = after_first
  end
  -- COMMENT keyword (Emacs `org-comment-string`).  Comes immediately
  -- after the stars or after the TODO state — `* COMMENT foo` and
  -- `* TODO COMMENT foo` both mark the entire subtree commented.
  -- Strict equality on the literal token (not a prefix match — a
  -- title beginning with "COMMENTARY" must not be flagged).
  local cw, after_comment = rest:match("^(%S+)%s*(.*)$")
  if cw == "COMMENT" then
    result.commented = true
    rest = after_comment
  end
  -- Emacs `org-priority-regexp` accepts `[A-Z0-9]` and treats the
  -- trailing space as optional ("\\] ?"), so `[#1]Stretch` (no space,
  -- numeric priority) is also valid.
  local pri, after_pri = rest:match("^%[#([%u%d])%]%s*(.*)$")
  if pri then
    result.priority = pri
    rest = after_pri
  end
  result.title = rest
  return result
end

local function parse_alias_value(s)
  local out = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == '"' then
      local close = s:find('"', i + 1, true)
      if not close then
        break
      end
      out[#out + 1] = s:sub(i + 1, close - 1)
      i = close + 1
    else
      local j = i
      while j <= #s and not s:sub(j, j):match("%s") do
        j = j + 1
      end
      out[#out + 1] = s:sub(i, j - 1)
      i = j
    end
  end
  return out
end

local function parse_filetags_value(value)
  local tags, seen = {}, {}
  for chunk in value:gmatch("[^:%s]+") do
    if not seen[chunk] then
      seen[chunk] = true
      tags[#tags + 1] = chunk
    end
  end
  table.sort(tags)
  return tags
end

local function scan_filetags(src)
  local set = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    local val = line:match("^%s*#%+[Ff][Ii][Ll][Ee][Tt][Aa][Gg][Ss]:%s*(.-)%s*$")
    if val then
      for _, t in ipairs(parse_filetags_value(val)) do
        set[t] = true
      end
    end
  end
  local tags = {}
  for t in pairs(set) do
    tags[#tags + 1] = t
  end
  table.sort(tags)
  return tags
end

-- Scan source text for `#+TODO:` / `#+TYP_TODO:` / `#+SEQ_TODO:`
-- directives.  Returns a list of `{ sequence_idx, ordinal, keyword,
-- is_done }` rows ready for SQL insertion.  Each directive line is
-- one sequence; multiple lines in the same file produce multiple
-- sequence_idx values (matching Emacs's per-file multi-sequence
-- behavior).  Annotation suffixes (`(t!)` etc.) are stripped before
-- storage; the bare keyword is what consumers compare against
-- `headlines.todo_state`.
local function scan_todo_keywords(src)
  local rows = {}
  local seq_idx = 0
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    local val = line:match("^%s*#%+[Tt][Oo][Dd][Oo]:%s*(.-)%s*$")
      or line:match("^%s*#%+[Tt][Yy][Pp]_[Tt][Oo][Dd][Oo]:%s*(.-)%s*$")
      or line:match("^%s*#%+[Ss][Ee][Qq]_[Tt][Oo][Dd][Oo]:%s*(.-)%s*$")
    if val and val ~= "" then
      seq_idx = seq_idx + 1
      local ord, in_done = 0, false
      for tok in val:gmatch("%S+") do
        if tok == "|" then
          in_done = true
        else
          ord = ord + 1
          local bare = tok:match("^([^(]+)") or tok
          rows[#rows + 1] = {
            sequence_idx = seq_idx,
            ordinal = ord,
            keyword = bare,
            is_done = in_done and 1 or 0,
          }
        end
      end
    end
  end
  return rows
end

local function trim_trailing_ws(s)
  return (s:gsub("[ \t]+$", ""))
end

local function get_text(node, src)
  if not node then
    return nil
  end
  return vim.treesitter.get_node_text(node, src)
end

local PLANNING_KW = { SCHEDULED = "scheduled", DEADLINE = "deadline", CLOSED = "closed" }

local function find_planning_node(heading_node)
  for c in heading_node:iter_children() do
    if c:type() == "planning" then
      return c
    end
    if c:type() == "section" then
      for sc in c:iter_children() do
        if sc:type() == "planning" then
          return sc
        end
      end
    end
  end
  return nil
end

local function extract_planning(heading_node, src)
  local out = { scheduled = nil, deadline = nil, closed = nil }
  local p = find_planning_node(heading_node)
  if not p then
    return out
  end
  -- Grammar: planning → planning_line+ → planning_entry+
  local function take_entry(entry)
    local kw_n = entry:field("keyword") and entry:field("keyword")[1] or nil
    local ts_n = entry:field("timestamp") and entry:field("timestamp")[1] or nil
    local kw = kw_n and get_text(kw_n, src) or nil
    local ts = ts_n and get_text(ts_n, src) or nil
    if kw and ts then
      local field = PLANNING_KW[kw]
      if field and not out[field] then
        out[field] = ts
      end
    end
  end
  for line in p:iter_children() do
    if line:type() == "planning_line" then
      for entry in line:iter_children() do
        if entry:type() == "planning_entry" then
          take_entry(entry)
        end
      end
    elseif line:type() == "planning_entry" then
      take_entry(line) -- direct child for legacy/single-line case
    end
  end
  return out
end

local function extract_properties(drawer_node, src)
  local list = {}
  if not drawer_node then
    return list
  end
  for c in drawer_node:iter_children() do
    if c:type() == "node_property" then
      -- Grammar exposes name + value as named children. Drop down
      -- to the field accessors and skip ad-hoc text parsing.
      local name_n = c:field("name") and c:field("name")[1] or nil
      local val_n = c:field("value") and c:field("value")[1] or nil
      local k = name_n and get_text(name_n, src) or nil
      local v = val_n and get_text(val_n, src) or ""
      if k and k ~= "" then
        table.insert(list, {
          key = k,
          value = trim_trailing_ws(v),
        })
      end
    end
  end
  return list
end

local function id_for(props, file_path, line_start)
  for _, p in ipairs(props) do
    if p.key == "ID" then
      return p.value
    end
  end
  return file_path .. "#L" .. tostring(line_start)
end

-- Parse the inside of a `<...>` / `[...]` org timestamp.  Mirrors
-- Emacs `org-ts-regexp-both` permissiveness:
--
--   YYYY-MM-DD [DAY] [H[H]:MM[-H[H]:MM]] [REPEATER] [WARNING]
--
-- where DAY is any non-whitespace token (locale-specific abbreviation
-- like "Wed", "金", "Lun.") and is OPTIONAL.  Hour can be 1 or 2
-- digits.  Repeater (`+1d` / `++1w` / `.+1m`) and warning (`-1d` /
-- `--1d`) suffixes after the time are skipped when extracting time.
--
-- Returns { date = "YYYY-MM-DD", time = "HH:MM" or nil }.  `time` is
-- always zero-padded to 2-digit hour even when the input had a single
-- digit, so downstream lex comparisons stay correct.
local function parse_ts_body(raw)
  if not raw then
    return nil
  end
  local body = raw:match("^[<%[](.-)[>%]]$") or raw
  local y, mo, d = body:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  local rest = body:sub(11) -- skip past YYYY-MM-DD
  -- Time: optional, may follow either the day-of-week token (with or
  -- without it) and may be a range (HH:MM-HH:MM) — only the start time
  -- is captured.  Repeater/warning suffixes after the time are
  -- ignored.  Pattern: any non-digit prefix (whitespace + optional
  -- day-of-week), then H[H]:MM.
  local h, mi = rest:match("^[^%d]*(%d%d?):(%d%d)")
  local out = { date = y .. "-" .. mo .. "-" .. d }
  if h and mi then
    out.time = string.format("%02d:%s", tonumber(h), mi)
  end
  return out
end

local function date_iso(raw)
  local p = parse_ts_body(raw)
  if not p then
    return nil
  end
  if p.time then
    return p.date .. "T" .. p.time
  end
  return p.date
end
M._date_iso = date_iso
M._parse_ts_body = parse_ts_body

-- Parse `[YYYY-MM-DD <Day> HH:MM]` (or `<...>`) into a unix timestamp.
-- Returns nil on malformed input.  Missing time defaults to 00:00.
local function ts_text_to_unix(text)
  local p = parse_ts_body(text)
  if not p then
    return nil
  end
  local y, mo, d = p.date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  local h, mi = 0, 0
  if p.time then
    h, mi = p.time:match("^(%d%d):(%d%d)$")
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = 0,
  })
end

-- Build a Lua pattern matching `^[ws]*:<DRAWER>:[ws]*$`
-- case-insensitively from the user's `todo.log_drawer` config.
-- Mirrors Emacs `org-log-into-drawer` (default "LOGBOOK"; users
-- with `(setq org-log-into-drawer "AUDIT")` get an :AUDIT: drawer
-- and we recognise it here so state-change extraction picks up).
local function log_drawer_pattern()
  local cfg = (require("organ").config and require("organ").config.todo) or {}
  local name = cfg.log_drawer or "LOGBOOK"
  local class = {}
  for c in name:gmatch(".") do
    local lo, hi = c:lower(), c:upper()
    if lo ~= hi then
      class[#class + 1] = "[" .. lo .. hi .. "]"
    else
      -- Escape regex metacharacters that might appear in a custom name.
      class[#class + 1] = c:gsub("([%.%%%+%-%*%?%[%]%(%)%^%$])", "%%%1")
    end
  end
  return "^%s*:" .. table.concat(class) .. ":%s*$"
end

local function collect_clocks(heading_node, src)
  local section_node = nil
  for c in heading_node:iter_children() do
    if c:type() == "section" then
      section_node = c
      break
    end
  end
  if not section_node then
    return {}
  end

  -- Grammar exposes (clock start: end: duration:) as named fields
  -- inside :LOGBOOK: drawers (and elsewhere). Walk every clock node
  -- under this section regardless of nesting depth.
  local clocks = {}
  local function visit(node)
    if node:type() == "clock" then
      local start_n = node:field("start") and node:field("start")[1] or nil
      local end_n = node:field("end") and node:field("end")[1] or nil
      local start_ts = start_n and ts_text_to_unix(get_text(start_n, src)) or nil
      local end_ts = end_n and ts_text_to_unix(get_text(end_n, src)) or nil
      if start_ts then
        clocks[#clocks + 1] = {
          start_ts = start_ts,
          end_ts = end_ts,
          duration_seconds = (end_ts and (end_ts - start_ts)) or nil,
        }
      end
      return
    end
    for c in node:iter_children() do
      visit(c)
    end
  end
  visit(section_node)
  return clocks
end

-- Extract State "DONE"-(or any "done" keyword) transitions from a
-- headline's LOGBOOK drawer, returning an ascending-sorted list of
-- YYYY-MM-DD strings.  Used by habit tracking.
local DONE_KEYWORDS = { DONE = true, CANCELLED = true }

local function collect_habit_completions(heading_node, src)
  local section_node = nil
  for c in heading_node:iter_children() do
    if c:type() == "section" then
      section_node = c
      break
    end
  end
  if not section_node then
    return {}
  end

  local sr, _, er = section_node:range()
  local section_lines
  if type(src) == "number" then
    section_lines = vim.api.nvim_buf_get_lines(src, sr, er, false)
  else
    section_lines = {}
    local i = 0
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
      if i >= sr and i < er then
        section_lines[#section_lines + 1] = line
      end
      i = i + 1
    end
  end

  local drawer_re = log_drawer_pattern()
  local seen, out = {}, {}
  local in_drawer = false
  for _, l in ipairs(section_lines) do
    if not in_drawer then
      if l:match(drawer_re) then
        in_drawer = true
      end
    else
      if l:match("^%s*:[Ee][Nn][Dd]:%s*$") then
        in_drawer = false
      else
        -- TODO keywords are any word per `org-todo-keywords`; not
        -- limited to uppercase.  Match `[%w_-]+` so `Verified`,
        -- `in_progress`, etc. all work.
        local kw, date =
          l:match('^%s*%-%s*State%s+"([%w_%-]+)"%s+from%s+"[%w_%-]*"%s*%[(%d%d%d%d%-%d%d%-%d%d)')
        if kw and DONE_KEYWORDS[kw] and not seen[date] then
          seen[date] = true
          out[#out + 1] = date
        end
      end
    end
  end
  table.sort(out)
  return out
end

-- Parse an Emacs LOGBOOK timestamp body into a Unix timestamp.  The
-- shape is `YYYY-MM-DD [DAY] [HH:MM]` per `org-ts-regexp-both` — DAY
-- and HH:MM are both optional, hours may be 1 or 2 digits.  Returns
-- the integer seconds-since-epoch interpreted in local time, with
-- 12:00 as a noon fallback when no time is present (matches Emacs's
-- `org-time-string-to-time` behavior of mid-day for date-only).
local function parse_logbook_ts(s)
  local p = parse_ts_body(s)
  if not p then
    return nil
  end
  local y, mo, d = p.date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  local h, mi = 12, 0
  if p.time then
    h, mi = p.time:match("^(%d%d):(%d%d)$")
  end
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
  })
end

-- Walk a headline's :LOGBOOK: drawer and return every state-change
-- entry as `{ ts, from_state, to_state, note }`.  Mirrors the regex
-- shape Emacs writes (`- State "X" from "Y" [YYYY-MM-DD Day HH:MM]
-- \\\n  optional note`); `from "" ` (transitioning from no state) is
-- normalised to from_state = nil.  Notes are collected from
-- continuation lines until the next `- ` bullet or :END:.
local function collect_state_changes(heading_node, src)
  local section_node = nil
  for c in heading_node:iter_children() do
    if c:type() == "section" then
      section_node = c
      break
    end
  end
  if not section_node then
    return {}
  end

  local sr, _, er = section_node:range()
  local section_lines
  if type(src) == "number" then
    section_lines = vim.api.nvim_buf_get_lines(src, sr, er, false)
  else
    section_lines = {}
    local i = 0
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
      if i >= sr and i < er then
        section_lines[#section_lines + 1] = line
      end
      i = i + 1
    end
  end

  local drawer_re = log_drawer_pattern()
  local out = {}
  local in_drawer = false
  local current -- accumulating the in-progress entry's continuation note
  local function flush()
    if current then
      out[#out + 1] = current
      current = nil
    end
  end
  for _, l in ipairs(section_lines) do
    if not in_drawer then
      if l:match(drawer_re) then
        in_drawer = true
      end
    else
      if l:match("^%s*:[Ee][Nn][Dd]:%s*$") then
        flush()
        in_drawer = false
      else
        local to_kw, from_kw, ts_body =
          l:match('^%s*%-%s*State%s+"([%w_%-]*)"%s+from%s+"([%w_%-]*)"%s*%[([^%]]+)%]')
        if to_kw and to_kw ~= "" then
          flush()
          local ts = parse_logbook_ts(ts_body)
          if ts then
            current = {
              ts = ts,
              to_state = to_kw,
              from_state = (from_kw == "" or from_kw == nil) and nil or from_kw,
              note = nil,
            }
          end
        elseif current and l:match("^%s*$") then
          -- Blank line ends the current entry's continuation block.
          flush()
        elseif current then
          local note_line = l:match("^%s*(.-)%s*$")
          if note_line ~= "" and not note_line:match("^%-") then
            current.note = current.note and (current.note .. "\n" .. note_line) or note_line
          elseif note_line:match("^%-") then
            -- Next bullet: close current, don't consume — it's another
            -- log entry that the next loop iteration will pick up via
            -- the State-pattern match.
            flush()
          end
        end
      end
    end
  end
  flush()
  return out
end

local function parse_link_text(text)
  local target, desc = text:match("^%[%[([^%]]+)%]%[([^%]]+)%]%]$")
  if target then
    return { target = target, description = desc }
  end
  local t2 = text:match("^%[%[([^%]]+)%]%]$")
  if t2 then
    return { target = t2, description = nil }
  end
  return nil
end

local function collect_all_inline_links(doc_parser, src)
  local links = {}
  if not doc_parser then
    return links
  end
  local ok, children = pcall(function()
    return doc_parser:children()
  end)
  if not ok then
    return links
  end
  for _, child_tree in pairs(children) do
    if child_tree:lang() == "org_inline" then
      for _, tree in ipairs(child_tree:trees()) do
        local function walk(node)
          local t = node:type()
          if t == "link_regular" or t == "link_plain" or t == "link_angle" then
            local row = node:range()
            local node_text = vim.treesitter.get_node_text(node, src)
            local parsed = parse_link_text(node_text)
            if parsed then
              links[#links + 1] = {
                target = parsed.target,
                description = parsed.description,
                line = row + 1,
              }
            end
          end
          for c in node:iter_children() do
            walk(c)
          end
        end
        walk(tree:root())
      end
    end
  end
  return links
end

local function collect_links(heading_node, all_links)
  if not all_links then
    return {}
  end
  local section_start, section_end
  for c in heading_node:iter_children() do
    if c:type() == "section" then
      local sr, _, er, _ = c:range()
      section_start = sr
      section_end = er
      break
    end
  end
  if not section_start then
    return {}
  end
  local out = {}
  for _, lk in ipairs(all_links) do
    local row = lk.line - 1
    if row >= section_start and row < section_end then
      out[#out + 1] = lk
    end
  end
  return out
end

local function collect_all_headings(node, out)
  if node:type() == "headline" then
    out[#out + 1] = node
  end
  for c in node:iter_children() do
    collect_all_headings(c, out)
  end
end

-- Sibling inline parser is colocated with the block parser. Works for
-- both the data-dir layout (`organ/parser/org.so`) and any
-- explicit override the user may have provided.
local function inline_parser_path(parser_path)
  if not parser_path then
    return nil
  end
  return (parser_path:gsub("/org%.so$", "/org_inline.so"))
end

-- Exposed for tests + downstream callers.
M._inline_parser_path = inline_parser_path

-- Add a tree-sitter language, surfacing arch-mismatch errors with an
-- actionable message. Returns (ok, err). Memoised on (name, path) — once
-- a language is loaded, repeat calls are a hash lookup.
local _lang_loaded = {}
local function safe_add_lang(name, path)
  if not path then
    return false, name .. " parser path is nil"
  end
  local key = name .. "\1" .. path
  if _lang_loaded[key] then
    return true
  end
  if not vim.uv.fs_stat(path) then
    return false, name .. " parser not built at " .. path
  end
  local ok, err = pcall(vim.treesitter.language.add, name, { path = path })
  if ok then
    _lang_loaded[key] = true
  end
  return ok, err
end

-- File-level metadata: a property_drawer that comes BEFORE the first heading
-- (org-roam convention) plus the `#+title:` directive. Surfaced as a
-- synthetic level-0 headline so query.get_by_id / query.headlines / find /
-- backlinks work with file-level :ID: links — just like in Emacs org-roam.
local function extract_file_level(root_node, src, file_path)
  if not root_node or not src then
    return nil
  end
  local file_drawer
  for c in root_node:iter_children() do
    if c:type() == "section" or c:type() == "headline" then
      break
    end
    if c:type() == "property_drawer" then
      file_drawer = c
      break
    end
    if c:type() == "body" or c:type() == "zeroth_section" then
      for sc in c:iter_children() do
        if sc:type() == "property_drawer" then
          file_drawer = sc
          break
        end
        if sc:type() == "section" or sc:type() == "headline" then
          break
        end
      end
      if file_drawer then
        break
      end
    end
  end
  if not file_drawer then
    return nil
  end

  local props = extract_properties(file_drawer, src)
  -- extract_properties returns a list of { key, value } records.
  local id
  for _, p in ipairs(props or {}) do
    if p.key == "ID" then
      id = p.value
      break
    end
  end
  if not id or id == "" then
    return nil
  end

  local title
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    local val = line:match("^%s*#%+[Tt][Ii][Tt][Ll][Ee]:%s*(.-)%s*$")
    if val then
      title = val
      break
    end
  end
  if not title or title == "" then
    title = file_path:match("([^/]+)%.org$") or file_path
  end

  return {
    id = id,
    parent_id = nil,
    level = 0,
    title = title,
    todo_state = nil,
    priority = nil,
    line_start = 0,
    line_end = 0,
    tags = {},
    properties = props or {},
    links = {},
    clocks = {},
    habit_completions = {},
  }
end

function M.extract(source, file_path, parser_path)
  local root_node, src_for_text
  local string_parser = nil

  local ipath = inline_parser_path(parser_path)
  if ipath then
    pcall(safe_add_lang, "org_inline", ipath)
  end

  local ok_lang, err_lang = safe_add_lang("org", parser_path)
  if not ok_lang then
    error("organ.indexer: " .. tostring(err_lang) .. " (rebuild on this host: `make -C grammar`)")
  end

  if type(source) == "number" then
    local bufnr = source
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
    if ok and parser then
      local tree = parser:parse()[1]
      root_node = tree:root()
      src_for_text = bufnr
    else
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local s = table.concat(lines, "\n") .. "\n"
      string_parser = vim.treesitter.get_string_parser(s, "org")
      root_node = string_parser:parse()[1]:root()
      src_for_text = s
    end
  else
    string_parser = vim.treesitter.get_string_parser(source, "org")
    root_node = string_parser:parse()[1]:root()
    src_for_text = source
  end

  if string_parser then
    pcall(function()
      string_parser:parse(true)
    end)
  end

  local all_inline_links = collect_all_inline_links(string_parser, src_for_text)

  local all_heading_nodes = {}
  collect_all_headings(root_node, all_heading_nodes)

  local headlines = {}
  local stack = {}

  -- File-level node (org-roam-style file with :ID: + #+title: in a
  -- property drawer before any heading). Emit before per-heading records
  -- so `query.get_by_id(<file-id>)` resolves it.
  local file_node = extract_file_level(root_node, src_for_text, file_path)
  if file_node then
    headlines[#headlines + 1] = file_node
  end

  for _, hnode in ipairs(all_heading_nodes) do
    local full_text = get_text(hnode, src_for_text) or ""
    local first_line = full_text:match("^[^\n]*") or ""
    local parsed = parse_heading_line(first_line)
    if not parsed then
      goto continue
    end

    local level = parsed.level
    local sr, _, er, _ = hnode:range()

    while #stack > 0 and stack[#stack].level >= level do
      table.remove(stack)
    end
    local parent_id = #stack > 0 and stack[#stack].id or nil

    local planning = extract_planning(hnode, src_for_text)
    local drawer_node = nil
    for c in hnode:iter_children() do
      if c:type() == "property_drawer" then
        drawer_node = c
        break
      end
      if c:type() == "section" then
        for sc in c:iter_children() do
          if sc:type() == "property_drawer" then
            drawer_node = sc
            break
          end
        end
        if drawer_node then
          break
        end
      end
    end
    local props = extract_properties(drawer_node, src_for_text)
    local id = id_for(props, file_path, sr)

    table.insert(headlines, {
      id = id,
      parent_id = parent_id,
      level = level,
      title = parsed.title,
      todo_state = parsed.todo,
      priority = parsed.priority,
      scheduled = planning.scheduled,
      deadline = planning.deadline,
      closed = planning.closed,
      scheduled_date = date_iso(planning.scheduled),
      deadline_date = date_iso(planning.deadline),
      closed_date = date_iso(planning.closed),
      line_start = sr,
      line_end = er,
      commented = parsed.commented and 1 or 0,
      tags = parsed.tags,
      properties = props,
      links = collect_links(hnode, all_inline_links),
      clocks = collect_clocks(hnode, src_for_text),
      habit_completions = collect_habit_completions(hnode, src_for_text),
      state_changes = collect_state_changes(hnode, src_for_text),
    })

    table.insert(stack, { level = level, id = id })

    ::continue::
  end

  if string_parser then
    pcall(function()
      string_parser:destroy()
    end)
  end
  return headlines
end

M.scan_filetags = scan_filetags
M.scan_todo_keywords = scan_todo_keywords

local db = require("organ.db")

local SQL = {
  ins_file = "INSERT OR REPLACE INTO files(path, mtime, hash, indexed, extractor_version) VALUES (?, ?, ?, strftime('%s','now'), ?)",
  del_hl = "DELETE FROM headlines WHERE file_path = ?",
  ins_hl = "INSERT INTO headlines(id, file_path, parent_id, level, title, "
    .. "todo_state, priority, scheduled, deadline, closed, "
    .. "scheduled_date, deadline_date, closed_date, "
    .. "line_start, line_end, commented) "
    .. "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  ins_tag = "INSERT INTO tags(headline_id, tag) VALUES (?, ?)",
  ins_prop = "INSERT INTO properties(headline_id, key, value) VALUES (?, ?, ?)",
  ins_link = "INSERT INTO links(source_headline_id, target_type, target, description, line) "
    .. "VALUES (?, ?, ?, ?, ?)",
  ins_clock = "INSERT INTO clock_entries(headline_id, start_ts, end_ts, duration_seconds) "
    .. "VALUES (?, ?, ?, ?)",
  ins_habit = "INSERT OR IGNORE INTO habit_completions(headline_id, date) VALUES (?, ?)",
  del_habit_for_hl = "DELETE FROM habit_completions WHERE headline_id = ?",
  ins_state = "INSERT OR REPLACE INTO state_changes(headline_id, ts, from_state, to_state, note) "
    .. "VALUES (?, ?, ?, ?, ?)",
  del_state_for_hl = "DELETE FROM state_changes WHERE headline_id = ?",
  upd_file_stamp = "UPDATE files SET mtime = ?, hash = ?, extractor_version = ? WHERE path = ?",
  del_file_tags = "DELETE FROM file_tags WHERE file_path = ?",
  ins_file_tag = "INSERT INTO file_tags (file_path, tag) VALUES (?, ?)",
  ins_alias = "INSERT INTO aliases (headline_id, alias) VALUES (?, ?)",
  del_file_todo_kw = "DELETE FROM file_todo_keywords WHERE file_path = ?",
  ins_file_todo_kw = "INSERT INTO file_todo_keywords"
    .. "(file_path, sequence_idx, ordinal, keyword, is_done) VALUES (?, ?, ?, ?, ?)",
}

local function get_stmts(h)
  if h._organ_stmts then
    return h._organ_stmts
  end
  local s = {}
  for name, sql in pairs(SQL) do
    local stmt, err = h:prepare(sql)
    if not stmt then
      for _, done in pairs(s) do
        done:finalize()
      end
      return nil, "prepare " .. name .. ": " .. tostring(err)
    end
    s[name] = stmt
  end
  h._organ_stmts = s
  return s
end

function M.write_body(h, meta, headlines, on_yield)
  local stmts, err = get_stmts(h)
  if not stmts then
    error(err)
  end

  -- Canonicalize once at the write boundary so every column in the DB
  -- shares a single path form (symlink-resolved + absolute).  Query
  -- callers canonicalize on the read side too — this keeps both sides
  -- aligned regardless of what form the caller passed in.
  meta.path = require("organ.path").canonical(meta.path) or meta.path

  local DONE = db.SQLITE_DONE

  stmts.ins_file:reset()
  stmts.ins_file:bind_text(1, meta.path)
  stmts.ins_file:bind_int64(2, 0)
  stmts.ins_file:bind_text(3, "")
  stmts.ins_file:bind_text(4, extractor_version())
  local rc = stmts.ins_file:step()
  if rc ~= DONE then
    error(string.format("ins_file rc=%d path=%s", rc, meta.path))
  end

  stmts.del_hl:reset()
  stmts.del_hl:bind_text(1, meta.path)
  local rc2 = stmts.del_hl:step()
  if rc2 ~= DONE then
    error(string.format("del_hl rc=%d path=%s", rc2, meta.path))
  end

  local row_chunk = h._organ_row_chunk or 10000
  local rows = 0
  for _, hl in ipairs(headlines) do
    stmts.ins_hl:reset()
    stmts.ins_hl:bind_text(1, hl.id)
    stmts.ins_hl:bind_text(2, meta.path)
    stmts.ins_hl:bind_text(3, hl.parent_id)
    stmts.ins_hl:bind_int(4, hl.level)
    stmts.ins_hl:bind_text(5, hl.title)
    stmts.ins_hl:bind_text(6, hl.todo_state)
    stmts.ins_hl:bind_text(7, hl.priority)
    stmts.ins_hl:bind_text(8, hl.scheduled)
    stmts.ins_hl:bind_text(9, hl.deadline)
    stmts.ins_hl:bind_text(10, hl.closed)
    stmts.ins_hl:bind_text(11, hl.scheduled_date)
    stmts.ins_hl:bind_text(12, hl.deadline_date)
    stmts.ins_hl:bind_text(13, hl.closed_date)
    stmts.ins_hl:bind_int(14, hl.line_start)
    stmts.ins_hl:bind_int(15, hl.line_end)
    stmts.ins_hl:bind_int(16, hl.commented or 0)
    local rch = stmts.ins_hl:step()
    if rch ~= DONE then
      error(string.format("ins_hl rc=%d path=%s id=%s", rch, meta.path, tostring(hl.id)))
    end

    for _, tag in ipairs(hl.tags or {}) do
      stmts.ins_tag:reset()
      stmts.ins_tag:bind_text(1, hl.id)
      stmts.ins_tag:bind_text(2, tag)
      local rct = stmts.ins_tag:step()
      if rct ~= DONE then
        error(string.format("ins_tag rc=%d id=%s tag=%s", rct, tostring(hl.id), tostring(tag)))
      end
    end
    for _, p in ipairs(hl.properties or {}) do
      stmts.ins_prop:reset()
      stmts.ins_prop:bind_text(1, hl.id)
      stmts.ins_prop:bind_text(2, p.key)
      stmts.ins_prop:bind_text(3, p.value)
      local rcp = stmts.ins_prop:step()
      if rcp ~= DONE then
        error(string.format("ins_prop rc=%d id=%s key=%s", rcp, tostring(hl.id), tostring(p.key)))
      end
    end
    for _, p in ipairs(hl.properties or {}) do
      if p.key == "ROAM_ALIASES" then
        for _, alias in ipairs(parse_alias_value(p.value or "")) do
          stmts.ins_alias:reset()
          stmts.ins_alias:bind_text(1, hl.id)
          stmts.ins_alias:bind_text(2, alias)
          local rca = stmts.ins_alias:step()
          if rca ~= DONE then
            error(
              string.format("ins_alias rc=%d id=%s alias=%s", rca, tostring(hl.id), tostring(alias))
            )
          end
        end
      end
    end
    local link_mod = require("organ.link")
    for _, lk in ipairs(hl.links or {}) do
      local ttype, tstrip = link_mod.resolve(lk.target)
      stmts.ins_link:reset()
      stmts.ins_link:bind_text(1, hl.id)
      stmts.ins_link:bind_text(2, ttype)
      stmts.ins_link:bind_text(3, tstrip)
      stmts.ins_link:bind_text(4, lk.description)
      stmts.ins_link:bind_int(5, lk.line)
      local rcl = stmts.ins_link:step()
      if rcl ~= DONE then
        error(
          string.format("ins_link rc=%d path=%s target=%s", rcl, meta.path, tostring(lk.target))
        )
      end
    end

    for _, c in ipairs(hl.clocks or {}) do
      stmts.ins_clock:reset()
      stmts.ins_clock:bind_text(1, hl.id)
      stmts.ins_clock:bind_int(2, c.start_ts)
      if c.end_ts then
        stmts.ins_clock:bind_int(3, c.end_ts)
        stmts.ins_clock:bind_int(4, c.duration_seconds or (c.end_ts - c.start_ts))
      else
        stmts.ins_clock:bind_null(3)
        stmts.ins_clock:bind_null(4)
      end
      local rcc = stmts.ins_clock:step()
      if rcc ~= DONE then
        error(string.format("ins_clock rc=%d id=%s", rcc, tostring(hl.id)))
      end
    end

    -- Habit completion dates from LOGBOOK State→DONE entries.  Always
    -- replace the per-headline set so completions removed from the file
    -- (manual edits) propagate to the index.
    if stmts.del_habit_for_hl and stmts.ins_habit then
      stmts.del_habit_for_hl:reset()
      stmts.del_habit_for_hl:bind_text(1, hl.id)
      stmts.del_habit_for_hl:step()
      for _, date in ipairs(hl.habit_completions or {}) do
        stmts.ins_habit:reset()
        stmts.ins_habit:bind_text(1, hl.id)
        stmts.ins_habit:bind_text(2, date)
        local rch = stmts.ins_habit:step()
        if rch ~= DONE then
          error(
            string.format("ins_habit rc=%d id=%s date=%s", rch, tostring(hl.id), tostring(date))
          )
        end
      end
    end

    -- Every state-change entry from the LOGBOOK drawer.  Replace the
    -- whole per-headline set on each pass so manual edits to the
    -- LOGBOOK propagate.  Powers `:Org agenda` log mode `state` item.
    if stmts.del_state_for_hl and stmts.ins_state then
      stmts.del_state_for_hl:reset()
      stmts.del_state_for_hl:bind_text(1, hl.id)
      stmts.del_state_for_hl:step()
      for _, sc in ipairs(hl.state_changes or {}) do
        stmts.ins_state:reset()
        stmts.ins_state:bind_text(1, hl.id)
        stmts.ins_state:bind_int(2, sc.ts)
        if sc.from_state then
          stmts.ins_state:bind_text(3, sc.from_state)
        else
          stmts.ins_state:bind_null(3)
        end
        stmts.ins_state:bind_text(4, sc.to_state)
        if sc.note and sc.note ~= "" then
          stmts.ins_state:bind_text(5, sc.note)
        else
          stmts.ins_state:bind_null(5)
        end
        local rcs = stmts.ins_state:step()
        if rcs ~= DONE then
          error(string.format("ins_state rc=%d id=%s ts=%d", rcs, tostring(hl.id), sc.ts))
        end
      end
    end

    rows = rows + 1
    if rows % row_chunk == 0 and on_yield then
      on_yield()
    end
  end

  stmts.upd_file_stamp:reset()
  stmts.upd_file_stamp:bind_int64(1, meta.mtime or 0)
  stmts.upd_file_stamp:bind_text(2, meta.hash or "")
  stmts.upd_file_stamp:bind_text(3, extractor_version())
  stmts.upd_file_stamp:bind_text(4, meta.path)
  local rcu = stmts.upd_file_stamp:step()
  if rcu ~= DONE then
    error(string.format("upd_file_stamp rc=%d path=%s", rcu, meta.path))
  end

  stmts.del_file_tags:reset()
  stmts.del_file_tags:bind_text(1, meta.path)
  local rcd = stmts.del_file_tags:step()
  if rcd ~= DONE then
    error(string.format("del_file_tags rc=%d path=%s", rcd, meta.path))
  end
  for _, tag in ipairs(meta.file_tags or {}) do
    stmts.ins_file_tag:reset()
    stmts.ins_file_tag:bind_text(1, meta.path)
    stmts.ins_file_tag:bind_text(2, tag)
    local rcft = stmts.ins_file_tag:step()
    if rcft ~= DONE then
      error(string.format("ins_file_tag rc=%d path=%s tag=%s", rcft, meta.path, tostring(tag)))
    end
  end

  -- File-level `#+TODO:` keywords (Emacs per-file todo overrides).
  stmts.del_file_todo_kw:reset()
  stmts.del_file_todo_kw:bind_text(1, meta.path)
  local rcdk = stmts.del_file_todo_kw:step()
  if rcdk ~= DONE then
    error(string.format("del_file_todo_kw rc=%d path=%s", rcdk, meta.path))
  end
  for _, kw in ipairs(meta.file_todo_keywords or {}) do
    stmts.ins_file_todo_kw:reset()
    stmts.ins_file_todo_kw:bind_text(1, meta.path)
    stmts.ins_file_todo_kw:bind_int(2, kw.sequence_idx)
    stmts.ins_file_todo_kw:bind_int(3, kw.ordinal)
    stmts.ins_file_todo_kw:bind_text(4, kw.keyword)
    stmts.ins_file_todo_kw:bind_int(5, kw.is_done)
    local rcfk = stmts.ins_file_todo_kw:step()
    if rcfk ~= DONE then
      error(string.format("ins_file_todo_kw rc=%d path=%s kw=%s", rcfk, meta.path, kw.keyword))
    end
  end
end

function M.write(h, meta, headlines, on_yield)
  local err = h:transaction(function()
    M.write_body(h, meta, headlines, on_yield)
  end)
  if not err then
    local ok, ev = pcall(require, "organ.events")
    if ok then
      ev.emit("indexed", { path = meta.path, n_headlines = #headlines })
    end
  end
  return err
end

function M.forget_body(h, path)
  local stmt, perr = h:prepare("DELETE FROM files WHERE path = ?")
  if not stmt then
    error("forget prepare: " .. tostring(perr))
  end
  stmt:bind_text(1, path)
  local rc = stmt:step()
  stmt:finalize()
  if rc ~= db.SQLITE_DONE then
    error(string.format("forget rc=%d path=%s", rc, path))
  end
  local ok, ev = pcall(require, "organ.events")
  if ok then
    ev.emit("unindexed", { path = path })
  end
end

function M.forget(h, path)
  local err = h:transaction(function()
    M.forget_body(h, path)
  end)
  return err
end

function M.forget_async(path)
  local q = require("organ.queue")
  q.enqueue_background_op({ kind = "delete", path = path })
end

function M.finalise_stmts(h)
  if not h._organ_stmts then
    return
  end
  for _, s in pairs(h._organ_stmts) do
    s:finalize()
  end
  h._organ_stmts = nil
end

-- Returns the number of rows currently in the `files` table — the
-- authoritative "is the index populated" signal.  Cheap; one COUNT query.
function M.files_count(h)
  local s, err = h:prepare("SELECT COUNT(*) FROM files")
  if not s then
    return 0, err
  end
  local n = 0
  if s:step() == db.SQLITE_ROW then
    n = s:column_int64(0)
  end
  s:finalize()
  return n
end

function M.should_skip(h, file_path, mtime, hash)
  -- Match the canonical form used by write_body so a path passed in
  -- raw (`/var/...` on macOS) finds the row written under its
  -- symlink-resolved form (`/private/var/...`).
  file_path = require("organ.path").canonical(file_path) or file_path
  local s, err = h:prepare("SELECT mtime, hash, extractor_version FROM files WHERE path = ?")
  if not s then
    return nil, err
  end
  s:bind_text(1, file_path)
  local step = s:step()
  local stored_mtime, stored_hash, stored_version
  if step == db.SQLITE_ROW then
    stored_mtime = s:column_int64(0)
    stored_hash = s:column_text(1)
    stored_version = s:column_text(2)
  end
  s:finalize()

  if stored_mtime == nil then
    return nil
  end
  -- Cache invalidation on extractor change: if the row was stamped
  -- with a different extractor_version (parser binary rebuild,
  -- indexer source modification, schema change), force-re-extract
  -- regardless of mtime/hash match.  Users never have to know about
  -- :Org scan! after an organ.nvim update — stale rows reroll
  -- transparently on the next scan.
  if stored_version ~= extractor_version() then
    return nil
  end
  if mtime ~= nil and stored_mtime == mtime then
    return "mtime"
  end
  if hash ~= nil and stored_hash == hash then
    return "hash"
  end
  return nil
end

function M.index_file_sync(path)
  local organ = require("organ")
  local h = require("organ.runtime").db()
  assert(h, "organ.runtime.db() returned nil — call organ.setup() before index_file_sync")
  local parser_path = organ.config.parser_path

  -- Canonicalize before any DB write so all `file_path` rows are
  -- symlink-resolved + absolute.  Without this, a caller indexing
  -- `/var/x/a.org` and then querying via `path.canonical(...)`
  -- (which resolves to `/private/var/x/a.org` on macOS) would miss
  -- the row.  Match the query side's canonicalization.
  path = require("organ.path").canonical(path) or path

  local f = assert(io.open(path, "r"))
  local src = f:read("*a")
  f:close()

  -- Hash short-circuit: byte-for-byte identical content → skip the parse +
  -- DB write. We deliberately don't use the mtime fast-path here: a save
  -- triggered within the same second as the prior index would falsely
  -- match. Per-file cost is one sha256 + one indexed SELECT.
  local hash = vim.fn.sha256(src)
  if M.should_skip(h, path, nil, hash) == "hash" then
    return
  end

  local st = vim.loop.fs_stat(path)
  local mtime = st and st.mtime.sec or 0

  local headlines = M.extract(src, path, parser_path)
  local file_tags = scan_filetags(src)
  local file_todo_keywords = scan_todo_keywords(src)
  local meta = {
    path = path,
    mtime = mtime,
    hash = hash,
    file_tags = file_tags,
    file_todo_keywords = file_todo_keywords,
  }

  local err = h:transaction(function()
    M.write_body(h, meta, headlines, function() end)
  end)
  if err then
    error("index_file_sync failed for " .. path .. ": " .. tostring(err))
  end
end

local function notify_msg(msg, level)
  if not (require("organ").config or {}).notify then
    return
  end
  vim.schedule(function()
    require("organ.notify").notify(level or vim.log.levels.INFO, msg)
  end)
end

M.commands = {
  index = {
    fn = function(cmd)
      local path = cmd.args ~= "" and cmd.args or vim.api.nvim_buf_get_name(0)
      if path == "" then
        require("organ.notify").error("no file")
        return
      end
      local canon = require("organ.path").canonical(path)
      if not canon then
        return
      end
      -- :Org index! force-reindexes by forgetting the existing DB row first,
      -- so the mtime/hash short-circuit can't skip a stale row from a
      -- previous parser version.
      if cmd.bang then
        M.forget(require("organ.runtime").db(), canon)
        notify_msg("force-reindex: " .. canon)
      end
      require("organ.queue").enqueue_interactive(canon)
    end,
    nargs = "?",
    complete = "file",
    bang = true,
    desc = "Reindex an org file. `:Org index!` clears the DB row first (fixes stale data).",
  },
  scan = {
    fn = function(cmd)
      local organ = require("organ")
      if cmd and cmd.bang then
        notify_msg("force-rescan: clearing index for " .. organ.config.org_dir)
        local h = require("organ.runtime").db()
        local s = h:prepare("SELECT path FROM files WHERE path LIKE ?")
        s:bind_text(1, organ.config.org_dir .. "%")
        local paths = {}
        while s:step() == require("organ.db").SQLITE_ROW do
          paths[#paths + 1] = s:column_text(0)
        end
        s:finalize()
        for _, p in ipairs(paths) do
          pcall(M.forget, h, p)
        end
      end
      notify_msg("scanning " .. organ.config.org_dir)
      organ._start_scan()
      organ._scan_walk(organ.config.org_dir, function()
        notify_msg("scan enqueued; draining in background")
        organ._poll_scan_completion()
      end)
    end,
    bang = true,
    desc = "Scan org_dir and index all .org files. `:Org scan!` clears the DB first.",
  },
  status = {
    fn = function()
      local organ = require("organ")
      local queue = require("organ.queue")
      local ui, bg = queue.depth()
      local indexed = 0
      local rt_ok, rt = pcall(require, "organ.runtime")
      if rt_ok then
        local h_ok, h = pcall(rt.db)
        if h_ok and h then
          indexed = M.files_count(h)
        end
      end
      local msg = string.format(
        "organ: db=%s  files_indexed=%d  queue(int/bg)=%d/%d  last=%s  errors=%d",
        organ.config.db_path,
        indexed,
        ui,
        bg,
        organ._last_status.last_file or "(none this session)",
        #organ._last_status.errors
      )
      local w = require("organ.watcher")
      local pending = 0
      for _ in pairs(w._tombstones or {}) do
        pending = pending + 1
      end
      msg = msg .. string.format("  watcher=%d/%d", #w.watched_dirs(), pending)
      vim.api.nvim_echo({ { msg, "None" } }, false, {})
    end,
    desc = "Show organ queue + DB status",
  },
  ["dump files"] = {
    fn = function()
      local h = require("organ.runtime").db()
      local db = require("organ.db")
      local s, err = h:prepare([[
        SELECT f.path, COUNT(hl.id) AS n
        FROM files f
        LEFT JOIN headlines hl ON hl.file_path = f.path
        GROUP BY f.path
        ORDER BY n ASC, f.path
      ]])
      if not s then
        require("organ.notify").error("dump_files: " .. tostring(err))
        return
      end
      local lines = {
        "Indexed files (path | headline count)",
        "Files with `headlines=0` are red flags — parser likely failed.",
        string.rep("-", 100),
      }
      while s:step() == db.SQLITE_ROW do
        lines[#lines + 1] = string.format("%6d  %s", s:column_int64(1), s:column_text(0) or "")
      end
      s:finalize()
      vim.cmd("vnew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.bo.buftype = "nofile"
      vim.bo.bufhidden = "wipe"
      vim.bo.modifiable = false
      vim.api.nvim_buf_set_name(0, "[OrgDumpFiles]")
    end,
    desc = "List indexed files with headline counts",
  },
  ["dump scheduled"] = {
    fn = function()
      local h = require("organ.runtime").db()
      local db = require("organ.db")
      local s, err = h:prepare([[
        SELECT file_path, title, todo_state, scheduled_date, deadline_date
        FROM headlines
        WHERE scheduled_date IS NOT NULL OR deadline_date IS NOT NULL
        ORDER BY file_path, scheduled_date, deadline_date
      ]])
      if not s then
        require("organ.notify").error("dump_scheduled: " .. tostring(err))
        return
      end
      local lines = {
        "Scheduled / deadline-bearing headlines in DB",
        "(file_path | TODO | scheduled | deadline | title)",
        string.rep("-", 100),
      }
      local n = 0
      while s:step() == db.SQLITE_ROW do
        n = n + 1
        local fp = (s:column_text(0) or ""):match("([^/]+/?[^/]*)$") or s:column_text(0)
        lines[#lines + 1] = string.format(
          "%-40s | %-6s | %-16s | %-10s | %s",
          fp,
          s:column_text(2) or "-",
          s:column_text(3) or "",
          s:column_text(4) or "",
          s:column_text(1) or ""
        )
      end
      s:finalize()
      lines[#lines + 1] = ""
      lines[#lines + 1] = string.format("(%d rows)", n)
      vim.cmd("vnew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      vim.bo.buftype = "nofile"
      vim.bo.bufhidden = "wipe"
      vim.bo.modifiable = false
      vim.api.nvim_buf_set_name(0, "[OrgDumpScheduled]")
    end,
    desc = "Open a scratch buffer with every scheduled/deadline headline in the DB",
  },
}

return M
