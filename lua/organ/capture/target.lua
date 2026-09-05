-- Capture target resolution.

local M = {}

local DEFAULT_DATETREE = { "%Y", "%Y-%m %B", "%Y-%m-%d %A" }

local function expand(p)
  return vim.fn.expand(p)
end

local function ensure_file(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  if not vim.loop.fs_stat(path) then
    vim.fn.writefile({}, path)
  end
end

local function read_lines(path)
  if not vim.loop.fs_stat(path) then
    return {}
  end
  return vim.fn.readfile(path)
end

-- Default TODO keyword list used to strip leading TODO tokens from
-- a headline title when the user hasn't configured `todo.sequence`.
-- Mirrors lua/organ/defaults.lua:861 (kept here to avoid a heavy
-- require during target resolution).
local FALLBACK_TODO_KEYWORDS = {
  "TODO",
  "NEXT",
  "WAITING",
  "HOLD",
  "PROJ",
  "DONE",
  "CANCELLED",
}

local function todo_keywords()
  local cfg = require("organ").config
  local seq = cfg and cfg.todo and cfg.todo.sequence
  if not seq then
    return FALLBACK_TODO_KEYWORDS
  end
  local out = {}
  for _, kw in ipairs(seq) do
    if kw ~= "|" then
      out[#out + 1] = kw
    end
  end
  return out
end

-- Strip Emacs `org-complex-heading-regexp-format` decorations from a
-- raw headline title so equality matching ignores: TODO keyword,
-- priority cookie `[#A]`, leading COMMENT prefix, leading and trailing
-- stats cookies `[1/3]` / `[33%]`, and trailing tags `:foo:bar:`.
--
-- See org-mode/lisp/org.el `org-complex-heading-regexp-format` for the
-- canonical structure we mirror.
local function bare_title(raw, kws)
  local s = raw or ""
  -- Trailing tags `:foo:bar:`.
  s = s:gsub("%s+:[%w_@#%%\128-\255:]+:%s*$", "")
  -- Trailing stats cookies `[2/5]` / `[40%%]`.
  s = s:gsub("%s*%[[%d%%/]+%]%s*$", "")
  -- Leading TODO keyword.
  for _, kw in ipairs(kws or FALLBACK_TODO_KEYWORDS) do
    local pat = "^" .. kw:gsub("(%W)", "%%%1") .. "%s+"
    if s:match(pat) then
      s = s:gsub(pat, "", 1)
      break
    end
  end
  -- Leading priority cookie `[#A]`.
  s = s:gsub("^%[#%w%]%s*", "")
  -- Leading COMMENT prefix.
  s = s:gsub("^COMMENT%s+", "")
  -- Leading stats cookies `[1/3]` / `[33%%]`.
  s = s:gsub("^%[[%d%%/]+%]%s*", "")
  -- Final trim.
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-- Parse the file into a list of headline records:
--   { line = 1-based, level = N, title = "Heading text", bare = "matchable" }
-- `title` is the raw text after stars (TODO/priority/tags preserved, used
-- for display in errors).  `bare` is what `find_headline` compares against
-- and what mirrors Emacs's `org-complex-heading-regexp-format` capture group.
local function parse_headlines(lines)
  local kws = todo_keywords()
  local hls = {}
  for i, l in ipairs(lines) do
    local stars, title = l:match("^(%*+)%s+(.-)%s*$")
    if stars then
      hls[#hls + 1] = {
        line = i,
        level = #stars,
        title = title,
        bare = bare_title(title, kws),
      }
    end
  end
  return hls
end

-- Returns (line_start, line_end). line_end is the line AFTER the section.
local function section_bounds(hls, hl_idx, total_lines)
  local hl = hls[hl_idx]
  if not hl then
    return nil
  end
  local end_line = total_lines + 1
  for j = hl_idx + 1, #hls do
    if hls[j].level <= hl.level then
      end_line = hls[j].line
      break
    end
  end
  return hl.line, end_line
end

-- Insertion line for `prepend`: the first child headline of `hl_idx`
-- (org-capture.el `outline-next-heading`), or the section end `e`
-- when it has none.
local function first_child_line(hls, hl_idx, e)
  local nxt = hls[hl_idx + 1]
  if nxt and nxt.line < e then
    return nxt.line
  end
  return e
end

-- Walk an outline path; returns the index in `hls` of the leaf, or nil.
-- Comparison uses each headline's bare title (TODO / priority / tags
-- stripped) so an olp like `{"Projects","Tasks"}` matches a real outline
-- like `* TODO Projects / ** [#A] Tasks :work:` (Emacs `org-find-olp`
-- behavior via org-complex-heading-regexp-format).
local function find_olp(hls, olp)
  if not olp or #olp == 0 then
    return nil
  end
  local depth = 0
  local last_idx
  for i, hl in ipairs(hls) do
    if hl.level == depth + 1 and hl.bare == olp[depth + 1] then
      depth = depth + 1
      last_idx = i
      if depth == #olp then
        return last_idx
      end
    elseif hl.level <= depth then
      depth = math.min(depth, hl.level - 1)
    end
  end
  return nil
end

-- Find first headline whose bare title (TODO / priority / COMMENT /
-- stats cookies / tags stripped per Emacs `org-complex-heading-regexp-format`)
-- exactly matches `title`.  Matches at any level.
local function find_headline(hls, title)
  for i, hl in ipairs(hls) do
    if hl.bare == title then
      return i
    end
  end
  return nil
end

local MONTH_NUMBERS

local function month_number(name)
  if not MONTH_NUMBERS then
    MONTH_NUMBERS = {}
    for m = 1, 12 do
      local t = os.time({ year = 2000, month = m, day = 15, hour = 12 })
      MONTH_NUMBERS[os.date("%B", t):lower()] = m
      MONTH_NUMBERS[os.date("%b", t):lower()] = m
    end
  end
  return MONTH_NUMBERS[name:lower()]
end

-- `os.date` directives a datetree level can sort by, with the position
-- they occupy in the sort key: year, then month or week, then day.
local DATE_FIELDS = {
  ["%Y"] = { rank = 1, pat = "(%d%d%d%d)" },
  ["%G"] = { rank = 1, pat = "(%d%d%d%d)" },
  ["%y"] = { rank = 1, pat = "(%d%d)" },
  ["%m"] = { rank = 2, pat = "(%d%d)" },
  ["%b"] = { rank = 2, pat = "(%a+)", decode = month_number },
  ["%h"] = { rank = 2, pat = "(%a+)", decode = month_number },
  ["%B"] = { rank = 2, pat = "(%a+)", decode = month_number },
  ["%V"] = { rank = 2, pat = "(%d%d)" },
  ["%W"] = { rank = 2, pat = "(%d%d)" },
  ["%U"] = { rank = 2, pat = "(%d%d)" },
  ["%j"] = { rank = 2, pat = "(%d%d%d)" },
  ["%d"] = { rank = 3, pat = "(%d%d)" },
  ["%e"] = { rank = 3, pat = "%s?(%d%d?)" },
}

local KEY_RANKS = 3

-- Lua pattern matching a title rendered from `fmt`, plus the ordered
-- list of the date fields it captures.
local function level_pattern(fmt)
  local pat = { "^" }
  local fields = {}
  local i = 1
  while i <= #fmt do
    local c = fmt:sub(i, i)
    if c ~= "%" or i == #fmt then
      pat[#pat + 1] = (c:gsub("%W", "%%%0"))
      i = i + 1
    else
      local spec = fmt:sub(i, i + 1)
      local field = DATE_FIELDS[spec]
      if field then
        pat[#pat + 1] = field.pat
        fields[#fields + 1] = field
      elseif spec == "%%" then
        pat[#pat + 1] = "%%"
      else
        pat[#pat + 1] = ".-"
      end
      i = i + 2
    end
  end
  return table.concat(pat), fields
end

-- Chronological sort key of a datetree headline, read through the
-- format that produced it ("%Y-%m %B" + "2026-03 March" -> {2026, 3, 0}).
-- Keying on the format rather than on the digits a title happens to
-- start with keeps "%Y-W%V" levels distinct and "%d-%m-%Y" levels in
-- order.  nil when the title does not match the format.
local function datetree_key(title, fmt)
  local pat, fields = level_pattern(fmt)
  if #fields == 0 then
    return nil
  end
  local caps = { title:match(pat) }
  if #caps < #fields then
    return nil
  end
  local key, seen = {}, {}
  for i = 1, KEY_RANKS do
    key[i] = 0
  end
  for i, field in ipairs(fields) do
    local value = field.decode and field.decode(caps[i]) or tonumber(caps[i])
    if not value then
      return nil
    end
    if not seen[field.rank] then
      key[field.rank], seen[field.rank] = value, true
    end
  end
  return key
end

local function key_cmp(a, b)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i] or 0, b[i] or 0
    if x ~= y then
      return x - y
    end
  end
  return 0
end

-- Datetree spine resolution (org-datetree.el
-- `org-datetree--find-create-subheading`).  Returns the deepest
-- existing spine headline index, the headlines still to create, and
-- the line they go on: before the first sibling that sorts later, else
-- at the end of the enclosing section.
local function resolve_datetree(hls, parent_idx, now, datetree_format, total_lines)
  local fmts = datetree_format or DEFAULT_DATETREE
  local titles = {}
  for _, fmt in ipairs(fmts) do
    titles[#titles + 1] = os.date(fmt, now)
  end
  local parent_level = parent_idx and hls[parent_idx].level or 0

  local current_idx = parent_idx
  local current_level = parent_level
  for level_offset, title in ipairs(titles) do
    local target_level = parent_level + level_offset
    local want = datetree_key(title, fmts[level_offset])
    local found, later
    local i = (current_idx and current_idx + 1) or 1
    while i <= #hls do
      local h = hls[i]
      if h.level <= current_level then
        break
      end
      if h.level == target_level then
        local have = datetree_key(h.title, fmts[level_offset])
        local c
        if have and want then
          c = key_cmp(have, want)
        elseif h.title == title then
          c = 0
        end
        if c == 0 then
          found = i
          break
        elseif c and c > 0 then
          later = i
          break
        end
      end
      i = i + 1
    end
    if found then
      current_idx = found
      current_level = target_level
    else
      local prelude = {}
      for k = level_offset, #titles do
        prelude[#prelude + 1] = string.rep("*", parent_level + k) .. " " .. titles[k]
      end
      local insert_line
      if later then
        insert_line = hls[later].line
      elseif current_idx then
        local _, e = section_bounds(hls, current_idx, total_lines)
        insert_line = e
      else
        insert_line = total_lines + 1
      end
      return current_idx, prelude, insert_line
    end
  end
  return current_idx, {}, nil
end

function M.resolve(spec, ctx, prepend)
  local kind = spec.kind

  if kind == "file_function" then
    local path, line = spec.fn(ctx or {})
    return path, line, {}
  end

  local path = expand(spec.path)
  ensure_file(path)
  local lines = read_lines(path)

  if kind == "file" then
    return path, #lines + 1, {}
  end

  if kind == "file_regexp" then
    -- Insert at the FIRST line whose text matches `regexp` (Lua
    -- pattern). Mirrors Emacs `(file+regexp "path" "regex")`. With
    -- `prepend`, insert ABOVE the matched line; otherwise below.
    if type(spec.regexp) ~= "string" or spec.regexp == "" then
      error("capture.target: file_regexp requires `regexp`")
    end
    for i, line in ipairs(lines) do
      if line:find(spec.regexp) then
        return path, prepend and i or (i + 1), {}
      end
    end
    error("capture.target: regex not matched in " .. path .. ": " .. spec.regexp)
  end

  local hls = parse_headlines(lines)

  if kind == "file_headline" then
    local idx = find_headline(hls, spec.headline)
    if not idx then
      -- Emacs `org-capture` for (file+headline ...) auto-creates the
      -- missing headline at end of file when not found; see
      -- org-mode/lisp/org-capture.el ~L1091-1098.  Mirror that here.
      -- The new headline lands as a top-level node; the captured
      -- entry re-levels to become its child via the standard
      -- parent_level path in capture.finalise.
      return path, #lines + 1, { "* " .. spec.headline }, 1
    end
    local _, e = section_bounds(hls, idx, #lines)
    -- Return the target's level as 4th value so capture.finalise
    -- can re-level the inserted entry to become a CHILD (level+1)
    -- instead of a sibling.  Mirrors Emacs's `entry`-type capture
    -- behavior; without it the captured `* TODO ...` lands at
    -- level 1 next to `* Inbox`, leaving a stray blank line and
    -- an awkward fold artifact.
    return path, prepend and first_child_line(hls, idx, e) or e, {}, hls[idx].level
  end

  if kind == "file_olp" then
    local idx = find_olp(hls, spec.olp)
    if not idx then
      error("capture.target: olp not found: " .. table.concat(spec.olp, " / "))
    end
    local _, e = section_bounds(hls, idx, #lines)
    return path, prepend and first_child_line(hls, idx, e) or e, {}, hls[idx].level
  end

  if kind == "file_olp_datetree" then
    local parent_idx
    local parent_level = 0
    if spec.olp and #spec.olp > 0 then
      parent_idx = find_olp(hls, spec.olp)
      if not parent_idx then
        error("capture.target: datetree parent olp not found: " .. table.concat(spec.olp, " / "))
      end
      parent_level = hls[parent_idx].level
    end
    local cfg = (require("organ.buf_config").read(nil, "capture") or {}).datetree_format
    local fmts = cfg or DEFAULT_DATETREE
    local leaf_level = parent_level + #fmts
    local leaf_idx, prelude, insert_line =
      resolve_datetree(hls, parent_idx, (ctx or {}).now or os.time(), cfg, #lines)

    if #prelude == 0 then
      local _, e = section_bounds(hls, leaf_idx, #lines)
      return path, prepend and first_child_line(hls, leaf_idx, e) or e, {}, leaf_level
    end
    return path, insert_line, prelude, leaf_level
  end

  error("capture.target: unknown kind: " .. tostring(kind))
end

return M
