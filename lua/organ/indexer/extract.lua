-- lua/organ/indexer/extract.lua
--
-- Walks the tree-sitter-organ block grammar (with org_inline injection)
-- to extract heading + planning + property + drawer metadata for the
-- SQLite index.
--
-- Inline structure (links, timestamps, heading sub-fields) is provided
-- by the injected tree-sitter-organ-inline grammar; this module walks
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
  local pp = organ.config and require("organ.buf_config").read(nil, "parser_path")
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
  local sp = organ.config and require("organ.buf_config").read(nil, "schema_path")
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
  local level, rest = require("organ.headline").split(line)
  if not level then
    return nil
  end
  local result =
    { level = level, todo = nil, priority = nil, title = "", tags = {}, commented = false }
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
M._parse_alias_value = parse_alias_value

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
  local cfg = (require("organ").config and require("organ.buf_config").read(nil, "todo")) or {}
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

-- Return the lines of a heading's `section` node, in the [sr, er)
-- half-open row range tree-sitter reports.  Buffer-source uses
-- nvim_buf_get_lines; string-source slices the caller-supplied
-- pre-split `src_lines` array.  Both are O(er - sr).
--
-- The string-source path REQUIRES src_lines.  Callers that pass a
-- string `src` must split it once at the top of the enclosing
-- extract loop and thread the resulting array through -- splitting
-- per-heading is the asymptotic trap (O(N_headings * file_size))
-- that this helper exists to prevent.
local function section_lines_for(section_node, src, src_lines)
  local sr, _, er = section_node:range()
  if type(src) == "number" then
    return vim.api.nvim_buf_get_lines(src, sr, er, false)
  end
  local out = {}
  for i = sr + 1, math.min(er, #src_lines) do
    out[#out + 1] = src_lines[i]
  end
  return out
end

local function collect_habit_completions(heading_node, src, src_lines)
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

  local section_lines = section_lines_for(section_node, src, src_lines)

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
local function collect_state_changes(heading_node, src, src_lines)
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

  local section_lines = section_lines_for(section_node, src, src_lines)

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

local function collect_all_inline_links(doc_parser, src, yield_fn)
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
          if yield_fn then
            yield_fn()
          end
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

local function collect_all_headings(node, out, yield_fn)
  if yield_fn then
    yield_fn()
  end
  if node:type() == "headline" then
    out[#out + 1] = node
  end
  for c in node:iter_children() do
    collect_all_headings(c, out, yield_fn)
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

-- Register the org + org_inline languages from the installed parser dir.
-- Idempotent; both extract and the async indexer call it before parsing.
function M.ensure_languages(parser_path)
  local ipath = inline_parser_path(parser_path)
  if ipath then
    pcall(safe_add_lang, "org_inline", ipath)
  end
  local ok_lang, err_lang = safe_add_lang("org", parser_path)
  if not ok_lang then
    error("organ.indexer: " .. tostring(err_lang) .. " (rebuild on this host: `make -C grammar`)")
  end
end

function M.extract(source, file_path, parser_path)
  local root_node, src_for_text
  local string_parser = nil

  M.ensure_languages(parser_path)

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

  local headlines = M._walk(root_node, string_parser, src_for_text, file_path)
  if string_parser then
    pcall(function()
      string_parser:destroy()
    end)
  end
  return headlines
end

-- Walk an already-parsed org tree into headline records.  `yield_fn`,
-- when given, is invoked throughout the walk (per inline node, per tree
-- node, per heading) so a cooperative caller can time-slice it (yield)
-- on large files.  The caller owns `string_parser`'s lifetime -- _walk
-- does not destroy it.
function M._walk(root_node, string_parser, src_for_text, file_path, yield_fn)
  local all_inline_links = collect_all_inline_links(string_parser, src_for_text, yield_fn)

  -- Pre-split string-source ONCE so per-heading helpers
  -- (collect_habit_completions, collect_state_changes) can slice
  -- the array in O(section_size) instead of re-scanning the whole
  -- source per heading (which is O(N_headings * file_size) and
  -- caused multi-second freezes on large org files).
  local src_lines = type(src_for_text) == "string"
      and vim.split(src_for_text, "\n", { plain = true })
    or nil

  local all_heading_nodes = {}
  collect_all_headings(root_node, all_heading_nodes, yield_fn)

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
    if yield_fn then
      yield_fn()
    end
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
      habit_completions = collect_habit_completions(hnode, src_for_text, src_lines),
      state_changes = collect_state_changes(hnode, src_for_text, src_lines),
    })

    table.insert(stack, { level = level, id = id })

    ::continue::
  end

  return headlines
end

M.scan_filetags = scan_filetags
M.scan_todo_keywords = scan_todo_keywords

return M
