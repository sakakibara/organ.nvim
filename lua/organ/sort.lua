-- Outline sorting -- Emacs org-sort-entries (C-c ^).
--
-- Sorts a set of sibling headlines, each carrying its whole subtree.
-- The set is the children of the headline at the cursor; before the
-- first headline it is the file's top-level entries, and over a range
-- it is the range's own entries.
--
-- `list sort` and `table sort` cover the other two things C-c ^ can
-- reach; this module is the headline half.

local M = {}

local obuf = require("organ.buf")

-- Sort keys, by organ's long name.  Emacs's single letters (`a`, `n`,
-- `o`, `p`, `r`, `s`, `d`, `t`, `c`, `k`, `f`) are accepted too, an
-- upper-case letter meaning "reversed" as it does there.
local ALIASES = {
  a = "alpha",
  n = "numeric",
  o = "todo",
  p = "priority",
  r = "property",
  s = "scheduled",
  d = "deadline",
  t = "timestamp",
  c = "created",
  k = "clocking",
  f = "func",
}

M.KEYS = {
  "alpha",
  "numeric",
  "todo",
  "priority",
  "property",
  "scheduled",
  "deadline",
  "timestamp",
  "created",
  "clocking",
  "func",
}

local NUMERIC = {
  numeric = true,
  todo = true,
  priority = true,
  scheduled = true,
  deadline = true,
  timestamp = true,
  created = true,
  clocking = true,
}

-- Resolve a user-facing sort spec to (key, reverse).  nil plus a reason
-- for anything unknown.
function M.resolve_key(spec)
  if spec == nil or spec == "" then
    return nil, "no sort key given"
  end
  if #spec == 1 then
    local lower = spec:lower()
    local key = ALIASES[lower]
    if not key then
      return nil, ("invalid sorting type: %s"):format(spec)
    end
    return key, spec ~= lower
  end
  local base, rev = spec, false
  local stripped = base:match("^(.*)_reverse$")
  if stripped then
    base, rev = stripped, true
  end
  for _, k in ipairs(M.KEYS) do
    if k == base then
      return k, rev
    end
  end
  return nil, ("invalid sorting type: %s"):format(spec)
end

local function level_of(text)
  local stars = text:match("^(%*+)%s")
  return stars and #stars or nil
end

-- Headline title with the TODO keyword, priority cookie, COMMENT
-- keyword and trailing tags removed -- Emacs `(org-get-heading t t t t)`.
local function bare_title(text, keywords)
  local body = text:match("^%*+%s+(.*)$") or ""
  local first, rest = body:match("^(%S+)%s*(.*)$")
  if first then
    for _, kw in ipairs(keywords) do
      if kw == first then
        body = rest
        break
      end
    end
  end
  body = body:gsub("^%[#%w%]%s*", "")
  body = body:gsub("%s+:[%w_@#%%\128-\255:]+:%s*$", "")
  if body:match("^COMMENT%s") or body == "COMMENT" then
    body = body:gsub("^COMMENT%s*", "")
  end
  return vim.trim(body)
end

local function todo_of(text, keywords)
  local first = (text:match("^%*+%s+(%S+)") or "")
  for _, kw in ipairs(keywords) do
    if kw == first then
      return kw
    end
  end
  return nil
end

-- Emacs `(- 99 (+/- (length (member m org-todo-keywords-1))))`: an
-- active keyword sorts before no keyword at all, which sorts before a
-- done one, and earlier keywords in the sequence sort first.
local function todo_rank(state, keywords, done)
  if not state then
    return 99
  end
  local idx
  for i, kw in ipairs(keywords) do
    if kw == state then
      idx = i
      break
    end
  end
  if not idx then
    return 99
  end
  local tail = #keywords - idx + 1
  return done[state] and (99 + tail) or (99 - tail)
end

local function first_match(lines, from, to, pattern)
  for i = from, to do
    local m = (lines[i] or ""):match(pattern)
    if m then
      return m
    end
  end
  return nil
end

-- Minutes summed over every closed CLOCK line in [from, to] -- Emacs
-- reads the subtree total that `org-clock-sum` leaves behind.
local function clock_minutes(lines, from, to)
  local ts = require("organ.timestamp")
  local total = 0
  for i = from, to do
    local text = lines[i] or ""
    if text:match("^%s*CLOCK:") then
      local a, b = ts.range_in(text)
      local t1, t2 = a and ts.to_seconds(a), b and ts.to_seconds(b)
      if t1 and t2 then
        total = total + math.floor(math.abs(t2 - t1) / 60)
      end
    end
  end
  return total
end

local function property_value(lines, from, to, name)
  local pattern = "^%s*:" .. name:gsub("(%W)", "%%%1") .. ":%s*(.-)%s*$"
  for i = from, to do
    local v = (lines[i] or ""):match(pattern)
    if v then
      return v
    end
  end
  return ""
end

-- Key for one record.  `own_end` is the last line of the entry proper
-- (before its first child), which is the window Emacs searches for a
-- timestamp; the clock sum covers the whole subtree.
local function record_key(rec, lines, key, ctx)
  local head = lines[rec.s] or ""
  if key == "alpha" then
    local t = bare_title(head, ctx.keywords)
    return ctx.with_case and t or t:lower()
  elseif key == "numeric" then
    return tonumber(bare_title(head, ctx.keywords):match("^%s*([-+]?%d+%.?%d*)") or "") or 0
  elseif key == "todo" then
    return todo_rank(todo_of(head, ctx.keywords), ctx.keywords, ctx.done)
  elseif key == "priority" then
    local p = head:match("%[#(%w+)%]") or ctx.priority_default
    return tonumber(p) or string.byte(p:upper())
  elseif key == "property" then
    return property_value(lines, rec.s, rec.own_end, ctx.property)
  elseif key == "clocking" then
    return clock_minutes(lines, rec.s, rec.e)
  elseif key == "func" then
    return ctx.getkey(rec.s, rec.e)
  end

  local ts = require("organ.timestamp")
  local raw
  if key == "scheduled" then
    raw = first_match(lines, rec.s, rec.own_end, "^%s*SCHEDULED:%s*([<%[][^>%]]+[>%]])")
  elseif key == "deadline" then
    raw = first_match(lines, rec.s, rec.own_end, "^%s*DEADLINE:%s*([<%[][^>%]]+[>%]])")
  elseif key == "created" then
    raw = first_match(lines, rec.s, rec.own_end, "^%s*(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])")
  else -- timestamp: an active stamp anywhere in the entry, else any stamp
    raw = first_match(lines, rec.s, rec.own_end, "(<%d%d%d%d%-%d%d%-%d%d[^>]*>)")
      or first_match(lines, rec.s, rec.own_end, "([<%[]%d%d%d%d%-%d%d%-%d%d[^>%]]*[>%]])")
  end
  return raw and ts.to_seconds(raw) or ctx.now
end

-- Locate the records to sort.  Returns { records, scope_end } or nil
-- plus a reason.  `line1`/`line2` describe an explicit range; without
-- one the cursor decides, as it does in Emacs.
local function collect(bufnr, line, line1, line2)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #lines
  local from, to
  if line1 and line2 and line2 > line1 then
    from, to = line1, line2
    -- Extend past the last selected subtree, as Emacs does.
    local lvl
    for i = from, to do
      lvl = lvl or level_of(lines[i] or "")
    end
    if lvl then
      while to < total do
        local l = level_of(lines[to + 1] or "")
        if l and l <= lvl then
          break
        end
        to = to + 1
      end
    end
  else
    local hl = require("organ.structure")._find_containing_headline(bufnr, line)
    if hl then
      from, to = hl.line + 1, require("organ.element_cache").subtree_end(bufnr, hl.line)
    else
      from, to = 1, total
    end
  end

  local first_line
  for i = from, to do
    if level_of(lines[i] or "") then
      first_line = i
      break
    end
  end
  if not first_line then
    return nil, "nothing to sort"
  end
  local lvl = level_of(lines[first_line])
  for i = first_line + 1, to do
    local l = level_of(lines[i] or "")
    if l and l < lvl then
      return nil, "region to sort contains a level above the first entry"
    end
  end

  local records = {}
  for i = first_line, to do
    local l = level_of(lines[i] or "")
    if l == lvl then
      if #records > 0 then
        records[#records].e = i - 1
      end
      records[#records + 1] = { s = i, e = to }
    end
  end
  if #records == 0 then
    return nil, "nothing to sort"
  end
  for _, rec in ipairs(records) do
    rec.own_end = rec.e
    for i = rec.s + 1, rec.e do
      if level_of(lines[i] or "") then
        rec.own_end = i - 1
        break
      end
    end
  end
  return { records = records, lines = lines, first = first_line, last = to }
end

-- Sort the sibling entries around (`bufnr`, `line`).
--   opts.key        sort spec ("alpha", "A", "priority", ...)
--   opts.with_case  compare case-sensitively (Emacs's prefix argument)
--   opts.property   property name for the `property` key
--   opts.getkey     key extractor for the `func` key: (s, e) -> value
--   opts.compare    comparison for `func`: (a, b) -> boolean
--   opts.line1/2    explicit line range instead of the cursor's scope
-- Returns the number of entries sorted, or nil plus a reason.
function M.entries(bufnr, line, opts)
  opts = opts or {}
  local key, rev = M.resolve_key(opts.key)
  if not key then
    return nil, rev
  end
  if opts.reverse then
    rev = not rev
  end
  if key == "property" and (opts.property == nil or opts.property == "") then
    return nil, "sorting by property needs a property name"
  end
  if key == "func" and type(opts.getkey) ~= "function" then
    return nil, "sorting by func needs a key function"
  end
  local scope, why = collect(bufnr, line, opts.line1, opts.line2)
  if not scope then
    return nil, why
  end

  local todo = require("organ.todo")
  local keywords = todo.all_keywords()
  local done = {}
  for _, seq in ipairs(todo.effective_sequences(bufnr) or {}) do
    local after_bar = false
    for _, kw in ipairs(seq) do
      if kw == "|" then
        after_bar = true
      elseif after_bar then
        done[kw] = true
      end
    end
  end
  local ctx = {
    keywords = keywords,
    done = done,
    with_case = opts.with_case,
    property = opts.property,
    getkey = opts.getkey,
    now = os.time(),
    priority_default = (require("organ.buf_config").read(bufnr, "priority") or {}).default or "B",
  }

  local decorated = {}
  for i, rec in ipairs(scope.records) do
    decorated[i] = { rec = rec, ord = i, key = record_key(rec, scope.lines, key, ctx) }
  end

  local less = opts.compare
  if not less then
    if NUMERIC[key] then
      less = function(a, b)
        return a < b
      end
    else
      less = function(a, b)
        return tostring(a) < tostring(b)
      end
    end
  end
  -- Stable: `sort-subr` keeps ties in buffer order, in both directions.
  table.sort(decorated, function(a, b)
    if less(a.key, b.key) then
      return not rev
    end
    if less(b.key, a.key) then
      return rev
    end
    return a.ord < b.ord
  end)

  local out = {}
  for _, d in ipairs(decorated) do
    for i = d.rec.s, d.rec.e do
      out[#out + 1] = scope.lines[i]
    end
  end
  obuf.set_lines(bufnr, scope.first - 1, scope.last, out)
  return #decorated
end

M.commands = {
  sort_entries = {
    fn = function(cmd)
      local args = (cmd and cmd.fargs) or {}
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local opts = {
        key = args[1],
        property = args[2],
        with_case = cmd and cmd.bang or false,
      }
      if cmd and cmd.range and cmd.range > 0 then
        opts.line1, opts.line2 = cmd.line1, cmd.line2
      end
      local function run()
        local n, why = M.entries(bufnr, line, opts)
        if not n then
          require("organ.notify").warn(why)
          return
        end
        require("organ.notify").info(("sorted %d entries (%s)"):format(n, opts.key))
      end
      if opts.key then
        run()
        return
      end
      vim.ui.select(M.KEYS, { prompt = "Sort entries by:" }, function(choice)
        if not choice then
          return
        end
        opts.key = choice
        if choice ~= "property" then
          run()
          return
        end
        vim.ui.input({ prompt = "Property: " }, function(name)
          if name and name ~= "" then
            opts.property = name
            run()
          end
        end)
      end)
    end,
    nargs = "*",
    bang = true,
    range = true,
    complete = function(arg_lead, cmdline)
      local after = cmdline:match("Org!?%s+sort_entries%s+(.*)$") or ""
      if #vim.split(after, "%s+", { trimempty = true }) > 1 or after:match("%s$") then
        return {}
      end
      local out = {}
      for _, k in ipairs(M.KEYS) do
        if k:sub(1, #arg_lead) == arg_lead then
          out[#out + 1] = k
        end
        local r = k .. "_reverse"
        if r:sub(1, #arg_lead) == arg_lead then
          out[#out + 1] = r
        end
      end
      table.sort(out)
      return out
    end,
    desc = "Sort the sibling headlines at cursor (Emacs C-c ^; `!` sorts case-sensitively)",
  },
}

return M
