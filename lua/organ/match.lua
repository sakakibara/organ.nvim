-- Emacs `org-make-tags-matcher` query language -> Lua predicate.
--
--   QUERY := TAGS-PART [ "/" [ "!" ] TODO-PART ]
--
-- TAGS-PART is a `|`-separated list of alternatives; each alternative is
-- an AND of terms.  A term is an optional `&`, an optional sign (`+`, `-`,
-- or `:` meaning `+`) and one of:
--
--   TAG             tag present ([[:alnum:]_@#%] plus non-ASCII bytes)
--   {pattern}       some tag matches the Lua pattern
--   PROP OP VALUE   property comparison.  OP is one of
--                   < <= = == >= <> != /=, optionally followed by `*`
--                   (the property must exist).  VALUE is "text" (string
--                   comparison), "<timestamp>" (time comparison),
--                   {pattern} (pattern match; <> / != / /= negate) or a
--                   number (numeric comparison; a missing or
--                   non-numeric property reads as 0).  LEVEL, TODO,
--                   CATEGORY, ITEM (the title), PRIORITY, SCHEDULED,
--                   DEADLINE and CLOSED are properties; PRIORITY with no
--                   cookie reads as `config.priority.default`, and the
--                   three planning names read the entry's planning line
--                   rather than its property drawer.
--
-- A quoted operand that opens with `<` or `[` and holds a date, `now`,
-- `today`, `tomorrow`, `yesterday` or an offset such as `+2d` compares
-- as time (Emacs `org-matcher-time`).  Offset units are h, d, w, m, y.
-- Both sides must parse as a timestamp or the term does not match.
--
-- TODO-PART is a `|`-separated list of alternatives of signed keywords or
-- {pattern} terms matched against the TODO state.  The `!` prefix limits
-- matches to entries in a not-done state, judged against the entry's own
-- `#+TODO:` keywords (the buffer's for a sparse tree, the file's index
-- entry for agenda rows, the global config otherwise).
--
-- A blank `|` alternative matches nothing.
--
-- Example:
--   `+work-home+EFFORT<60/+NEXT|-DONE` -> headlines tagged work without
--   home whose EFFORT is below 60, in state NEXT or in any state but DONE.

local M = {}

local TAG_CHAR = "[%w_@#%%\128-\255]"

local OPERATORS = { "<=", ">=", "==", "<>", "!=", "/=", "<", ">", "=" }

local CANONICAL_OP = {
  ["<="] = "<=",
  [">="] = ">=",
  ["=="] = "==",
  ["="] = "==",
  ["<>"] = "~=",
  ["!="] = "~=",
  ["/="] = "~=",
  ["<"] = "<",
  [">"] = ">",
}

-- Timestamps.

local TIME_WORDS = { "now", "today", "tomorrow", "yesterday" }

local OFFSET_UNIT = {
  h = 3600,
  d = 86400,
  w = 604800,
  m = 2678400,
  y = 31557600,
}

-- Emacs `org-make-tags-matcher` timep: a bracketed operand naming a date
-- or one of the relative forms.
local function is_time_operand(value)
  local body = value:match("^[%[<](.*)[%]>]$")
  if not body then
    return false
  end
  if body:match("^%d") or body:match("^[-+]%d+[hdwmy]") then
    return true
  end
  for _, word in ipairs(TIME_WORDS) do
    if body:sub(1, #word) == word then
      return true
    end
  end
  return false
end

-- Epoch seconds of the first `YYYY-MM-DD[ HH:MM]` in `s`, or nil.
local function timestamp_seconds(s)
  s = tostring(s or "")
  local first, last = s:find("%d%d%d%d%-%d%d%-%d%d")
  if not first then
    return nil
  end
  local y, mo, d = s:sub(first, last):match("^(%d+)%-(%d+)%-(%d+)$")
  local h, mi = s:sub(last + 1):match("^%D*(%d%d?):(%d%d)")
  return os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h) or 0,
    min = tonumber(mi) or 0,
    sec = 0,
  })
end

local function now_ts()
  return require("organ.agenda.dates").now_ts()
end

local function today_ts()
  local t = os.date("*t", now_ts())
  return os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
end

-- Emacs `org-matcher-time`: resolve a time operand to epoch seconds.
local function matcher_time(value)
  if value == "<now>" then
    return now_ts()
  elseif value == "<today>" then
    return today_ts()
  elseif value == "<tomorrow>" then
    return today_ts() + 86400
  elseif value == "<yesterday>" then
    return today_ts() - 86400
  end
  local n, unit = value:match("^<([-+]%d+)([hdwmy])>$")
  if n then
    local base = unit == "h" and now_ts() or today_ts()
    return base + tonumber(n) * OFFSET_UNIT[unit]
  end
  return timestamp_seconds(value)
end

-- Parser.

local function read_pattern(s, i)
  local close = s:find("}", i + 1, true)
  if not close then
    error("match: unterminated {pattern} in " .. s)
  end
  return s:sub(i + 1, close - 1), close + 1
end

local function read_operand(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local pat, j = read_pattern(s, i)
    return { kind = "pattern", value = pat }, j
  end
  if c == '"' then
    local close = s:find('"', i + 1, true)
    if not close then
      error('match: unterminated "value" in ' .. s)
    end
    local value = s:sub(i + 1, close - 1)
    return { kind = is_time_operand(value) and "time" or "string", value = value }, close + 1
  end
  local num = s:match("^%-?[%.%d]+[eE][-+]?%d+", i) or s:match("^%-?[%.%d]+", i)
  if num then
    return { kind = "number", value = tonumber(num) or 0 }, i + #num
  end
  return nil
end

local function read_term(s, i, todo_part)
  if s:sub(i, i) == "&" then
    i = i + 1
  end
  local negate = false
  local c = s:sub(i, i)
  if c == "+" or c == "-" or c == ":" then
    negate = c == "-"
    i = i + 1
    c = s:sub(i, i)
  end
  if c == "{" then
    local pat, j = read_pattern(s, i)
    return { kind = "pattern", negate = negate, value = pat }, j
  end
  if not todo_part then
    local name = s:match("^[%w_]+", i)
    if name then
      local j = i + #name
      local op
      for _, candidate in ipairs(OPERATORS) do
        if s:sub(j, j + #candidate - 1) == candidate then
          op = candidate
          break
        end
      end
      if op then
        j = j + #op
        local must_exist = false
        if s:sub(j, j) == "*" then
          must_exist = true
          j = j + 1
        end
        local operand, k = read_operand(s, j)
        if not operand then
          error(
            string.format("match: expected a value after %s%s at position %d in %s", name, op, j, s)
          )
        end
        return {
          kind = "property",
          negate = negate,
          key = name:upper(),
          op = CANONICAL_OP[op],
          operand = operand,
          must_exist = must_exist,
        },
          k
      end
    end
  end
  local word = s:match("^" .. TAG_CHAR .. "+", i)
  if not word then
    error(string.format("match: unexpected character %q at position %d in %s", c, i, s))
  end
  return { kind = todo_part and "todo" or "tag", negate = negate, value = word }, i + #word
end

-- Split `s` on `|` and parse each alternative into a list of terms.
-- Blank alternatives are dropped (Emacs `org-split-string`), so they
-- match nothing rather than everything.  Returns nil when `s` is blank.
local function parse_alternatives(s, todo_part)
  if not s or s:match("^%s*$") then
    return nil
  end
  local alternatives = {}
  for alt in (s .. "|"):gmatch("(.-)|") do
    if not alt:match("^%s*$") then
      local terms = {}
      local i, n = 1, #alt
      while i <= n do
        if alt:sub(i, i):match("%s") then
          i = i + 1
        else
          local term
          term, i = read_term(alt, i, todo_part)
          terms[#terms + 1] = term
        end
      end
      alternatives[#alternatives + 1] = terms
    end
  end
  return alternatives
end

-- Returns { tags = alternatives?, todo = alternatives?, todo_only = bool }.
function M.parse(query)
  if not query or query == "" then
    error("match: empty query")
  end
  local tags_str, todo_str = query, nil
  local last_s, last_e
  local pos = 1
  while true do
    local s, e = query:find("/+", pos)
    if not s then
      break
    end
    last_s, last_e = s, e
    pos = e + 1
  end
  if last_s and not query:find('"', last_s, true) then
    tags_str = query:sub(1, last_s - 1)
    todo_str = query:sub(last_e + 1)
  end
  local todo_only = false
  if todo_str and todo_str:sub(1, 1) == "!" then
    todo_only = true
    todo_str = todo_str:sub(2)
  end
  return {
    tags = parse_alternatives(tags_str, false),
    todo = parse_alternatives(todo_str, true),
    todo_only = todo_only,
  }
end

-- Evaluator. headline = { todo_state, tags = {...}, level, title, properties }

-- Resolve config.tags.groups: a parent tag matches when ANY member tag is
-- present on the headline (mirrors Emacs `:startgrouptag`/`:grouptags`/
-- `:endgrouptag` semantics).
local function _tag_group_index()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return (require("organ.buf_config").read(nil, "tags") or {}).groups or {}
end

local function _tag_in_set(name, headline_tags, groups)
  for _, ht in ipairs(headline_tags or {}) do
    if ht == name then
      return true
    end
  end
  local members = groups[name]
  if members then
    for _, m in ipairs(members) do
      for _, ht in ipairs(headline_tags or {}) do
        if ht == m then
          return true
        end
      end
    end
  end
  return false
end

local function any_tag_matches(pattern, headline_tags)
  for _, ht in ipairs(headline_tags or {}) do
    local ok, hit = pcall(string.match, ht, pattern)
    if ok and hit then
      return true
    end
  end
  return false
end

-- Emacs `string-to-number`: the leading numeric prefix, else 0.
local function to_number(s)
  s = tostring(s or "")
  local num = s:match("^%s*([-+]?%d+%.?%d*[eE][-+]?%d+)")
    or s:match("^%s*([-+]?%d*%.%d+)")
    or s:match("^%s*([-+]?%d+)")
  return num and tonumber(num) or 0
end

local function compare(op, a, b)
  if op == "==" then
    return a == b
  elseif op == "~=" then
    return a ~= b
  elseif op == "<" then
    return a < b
  elseif op == "<=" then
    return a <= b
  elseif op == ">" then
    return a > b
  end
  return a >= b
end

-- Emacs `org-special-properties`: these never come from a property
-- drawer, so a `:DEADLINE:` drawer entry is invisible to a DEADLINE term.
local SPECIAL_FIELD = { SCHEDULED = "scheduled", DEADLINE = "deadline", CLOSED = "closed" }

local function property_value(h, key)
  if key == "LEVEL" then
    return h.level and tostring(h.level) or nil
  elseif key == "TODO" then
    return h.todo_state
  elseif key == "CATEGORY" then
    return require("organ.agenda.format").category_for(h)
  elseif key == "ITEM" then
    return h.title
  elseif key == "PRIORITY" then
    return h.priority or require("organ.buf_config").read(nil, "priority.default") or "B"
  elseif SPECIAL_FIELD[key] then
    local v = h[SPECIAL_FIELD[key]]
    return (v ~= nil and v ~= "") and v or nil
  end
  local props = h.properties or {}
  if props[key] ~= nil then
    return props[key]
  end
  for k, v in pairs(props) do
    if type(k) == "string" and k:upper() == key then
      return v
    end
  end
  return nil
end

local function property_matches(term, h)
  local gv = property_value(h, term.key)
  local operand = term.operand
  local hit
  if operand.kind == "pattern" then
    local ok, m = pcall(string.match, gv or "", operand.value)
    hit = ok and m ~= nil
    if term.op == "~=" then
      hit = not hit
    end
  elseif operand.kind == "time" then
    local a = gv and timestamp_seconds(gv)
    local b = matcher_time(operand.value)
    hit = a ~= nil and b ~= nil and a > 0 and b > 0 and compare(term.op, a, b)
  elseif operand.kind == "string" then
    hit = compare(term.op, gv or "", operand.value)
  else
    hit = compare(term.op, to_number(gv), operand.value)
  end
  if term.must_exist and gv == nil then
    hit = false
  end
  return hit
end

local function term_matches(term, h, groups)
  local hit
  if term.kind == "tag" then
    hit = _tag_in_set(term.value, h.tags, groups)
  elseif term.kind == "pattern" then
    hit = any_tag_matches(term.value, h.tags)
  else
    hit = property_matches(term, h)
  end
  if term.negate then
    return not hit
  end
  return hit
end

local function todo_term_matches(term, h)
  local hit
  if term.kind == "pattern" then
    local ok, m = pcall(string.match, h.todo_state or "", term.value)
    hit = ok and m ~= nil
  else
    hit = h.todo_state == term.value
  end
  if term.negate then
    return not hit
  end
  return hit
end

local function alternatives_match(alternatives, h, match_term, groups)
  for _, terms in ipairs(alternatives) do
    local all = true
    for _, term in ipairs(terms) do
      if not match_term(term, h, groups) then
        all = false
        break
      end
    end
    if all then
      return true
    end
  end
  return false
end

-- Active keywords of a file's own `#+TODO:` directives, from the index.
local function file_active_keywords(path)
  local ok, q = pcall(require, "organ.query")
  if not ok or type(q.file_todo_keywords) ~= "function" then
    return nil
  end
  local ok2, map = pcall(q.file_todo_keywords, { path })
  local entry = ok2 and map and map[path]
  return entry and entry.active or nil
end

-- `/!` restricts to entries whose state is active under the keywords
-- that govern the entry: the buffer's when the query runs against one,
-- else the entry's own file, else the global config.
local function active_state_test(bufnr)
  local todo = require("organ.todo")
  local cache = {}
  return function(h)
    local state = h.todo_state
    if not state then
      return false
    end
    if bufnr then
      cache.buf = cache.buf or todo.effective_sequences(bufnr)
      return todo._is_active(state, cache.buf)
    end
    local path = h.file_path
    if path then
      local set = cache[path]
      if set == nil then
        set = file_active_keywords(path) or false
        cache[path] = set
      end
      if set then
        return set[state] == true
      end
    end
    cache.global = cache.global or todo.effective_sequences(nil)
    return todo._is_active(state, cache.global)
  end
end

-- Build a predicate function compatible with sparse.apply.
-- `opts.bufnr` names the buffer the query runs against, so `/!` can
-- honour its in-buffer `#+TODO:` keywords.
function M.predicate(query, opts)
  local parsed = M.parse(query)
  local is_active = parsed.todo_only and active_state_test(opts and opts.bufnr)
  return function(h)
    if is_active and not is_active(h) then
      return false
    end
    local groups = _tag_group_index()
    if parsed.tags and not alternatives_match(parsed.tags, h, term_matches, groups) then
      return false
    end
    if parsed.todo and not alternatives_match(parsed.todo, h, todo_term_matches) then
      return false
    end
    return true
  end
end

return M
