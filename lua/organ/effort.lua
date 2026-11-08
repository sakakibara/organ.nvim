local M = {}

local duration = require("organ.duration")

--- Minutes of an effort value as org-duration reads it, or nil for a
--- non-string, a blank value, or one org-duration cannot read.
function M.parse(s)
  if type(s) ~= "string" or not s:find("[^ \t]") then
    return nil
  end
  return (duration.to_minutes(s))
end

-- Sum clock entries belonging to a row. `clock_entries` is a list of
-- { start_ts, end_ts, duration_seconds } records produced by
-- `query.clock_entries({ headline_id = id })`.
function M.clocked_minutes(clock_entries)
  if not clock_entries or #clock_entries == 0 then
    return 0
  end
  local total = 0
  for _, c in ipairs(clock_entries) do
    if c.duration_seconds then
      total = total + c.duration_seconds
    end
  end
  return math.floor(total / 60 + 0.5)
end

-- Parse an effort filter expression into a predicate fn(minutes) -> bool.
--   "<30"           -> less than 30 minutes
--   ">=1:00"        -> at least 60 minutes
--   "1:00..2:00"    -> between 60 and 120 minutes inclusive
--   "60"            -> exactly 60 minutes
--   ""              -> matches everything
-- Each value is read as an effort value. Returns predicate, or
-- (nil, error_message) on a malformed input.
function M.parse_filter(spec)
  spec = (spec or ""):match("^%s*(.-)%s*$")
  if spec == "" then
    return function()
      return true
    end
  end

  local lo_s, hi_s = spec:match("^(.-)%.%.(.*)$")
  if lo_s and hi_s then
    local lo = M.parse(lo_s)
    local hi = M.parse(hi_s)
    if not lo or not hi then
      return nil, "bad range bounds: " .. spec
    end
    return function(min)
      return min and min >= lo and min <= hi
    end
  end

  local op, val_s = spec:match("^([<>]=?)%s*(.+)$")
  if op then
    local v = M.parse(val_s)
    if not v then
      return nil, "bad value: " .. val_s
    end
    if op == "<" then
      return function(m)
        return m and m < v
      end
    end
    if op == ">" then
      return function(m)
        return m and m > v
      end
    end
    if op == "<=" then
      return function(m)
        return m and m <= v
      end
    end
    if op == ">=" then
      return function(m)
        return m and m >= v
      end
    end
  end

  local v = M.parse(spec)
  if v then
    return function(m)
      return m == v
    end
  end
  return nil, "could not parse: " .. spec
end

function M.row_effort_minutes(row)
  if not row or not row.properties then
    return nil
  end
  local raw = row.properties.EFFORT or row.properties.Effort or row.properties.effort
  return M.parse(raw)
end

-- TD-94 migration: delete after 2027-02-09
-- "month" and the value with each `m` unit spelled `min`, "invalid" and
-- to_minutes's message, or nil.
local function classify(value)
  local minutes, msg = duration.to_minutes(value)
  if not minutes then
    return "invalid", nil, msg
  end
  local parts, from = {}, 1
  for _, t in ipairs(duration.unit_tokens(value)) do
    if value:sub(t[1], t[2] - 1) == "m" then
      parts[#parts + 1] = value:sub(from, t[1] - 1) .. "min"
      from = t[2]
    end
  end
  if from == 1 then
    return nil
  end
  parts[#parts + 1] = value:sub(from)
  return "month", table.concat(parts)
end

local function effort_key(key)
  key = key:lower()
  if key == "effort" then
    return "one"
  elseif key == "effort_all" then
    return "all"
  end
  return nil
end

--- Every Effort and Effort_ALL value in the org tree at `root` (source
--- `src`) that a reader of org-duration must change or cannot read: the
--- properties of the file-level and headline property drawers and the
--- `#+PROPERTY:` keywords, keys matched case-insensitively, an _ALL value
--- split on blanks.  Each finding is { line, col, end_col, value, kind,
--- replacement, message }: `line` 1-based, `col`..`end_col` the value's
--- 0-based end-exclusive byte columns, `kind` "month" (with
--- `replacement`) or "invalid" (with `message`).  Sorted by position.
function M.scan(root, src)
  local findings = {}

  local function visit(value, row, col, mode)
    local first = 1
    while true do
      local s, e
      if mode == "all" then
        s, e = value:find("[^ \t]+", first)
      else
        s = value:find("[^ \t]")
        e = s and value:find("[ \t]*$") - 1
      end
      if not s then
        return
      end
      local v = value:sub(s, e)
      local kind, replacement, message = classify(v)
      if kind then
        findings[#findings + 1] = {
          line = row + 1,
          col = col + s - 1,
          end_col = col + e,
          value = v,
          kind = kind,
          replacement = replacement,
          message = message,
        }
      end
      if mode ~= "all" then
        return
      end
      first = e + 1
    end
  end

  local function child(node, type_)
    for c in node:iter_children() do
      if c:type() == type_ then
        return c
      end
    end
    return nil
  end

  local function drawer(node)
    if not node then
      return
    end
    for p in node:iter_children() do
      if p:type() == "node_property" then
        local name = child(p, "property_name")
        local val = child(p, "property_value")
        local mode = name and effort_key(vim.treesitter.get_node_text(name, src))
        if mode and val then
          local row, col = val:range()
          visit(vim.treesitter.get_node_text(val, src), row, col, mode)
        end
      end
    end
  end

  local function keyword(node)
    local name = child(node, "directive_name")
    local val = child(node, "directive_value")
    if not (name and val) or vim.treesitter.get_node_text(name, src):lower() ~= "property" then
      return
    end
    local text = vim.treesitter.get_node_text(val, src)
    local key, rest = text:match("^(%S+)[ \t]+()")
    local mode = key and effort_key(key)
    if mode then
      local row, col = val:range()
      visit(text:sub(rest), row, col + rest - 1, mode)
    end
  end

  local function walk(node)
    local t = node:type()
    if t == "headline" then
      drawer(child(node, "property_drawer"))
    elseif t == "keyword" then
      keyword(node)
    end
    for c in node:iter_children() do
      if c:named() then
        walk(c)
      end
    end
  end

  drawer(require("organ.indexer.extract").file_property_drawer(root))
  walk(root)
  table.sort(findings, function(a, b)
    return a.line < b.line or (a.line == b.line and a.col < b.col)
  end)
  return findings
end

-- TD-94 migration: delete after 2027-02-09
--- :Org migrate_effort: rewrite every "month" value M.scan finds in
--- buffer `bufnr` in one undo step, and list the "invalid" ones in the
--- current window's location list.
function M.migrate(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local notify = require("organ.notify")
  local root = require("organ.element").root(bufnr)
  if not root then
    notify.error("migrate_effort: no org parser for this buffer")
    return
  end
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"
  local findings = M.scan(root, src)

  local rewritten, items, shift = 0, {}, {}
  for _, f in ipairs(findings) do
    local delta = shift[f.line] or 0
    if f.kind == "month" then
      shift[f.line] = delta + #f.replacement - #f.value
    else
      items[#items + 1] = {
        bufnr = bufnr,
        lnum = f.line,
        col = f.col + delta + 1,
        text = ("invalid effort: %s (%s)"):format(f.value, f.message),
      }
    end
  end
  for i = #findings, 1, -1 do
    local f = findings[i]
    if f.kind == "month" then
      vim.api.nvim_buf_set_text(bufnr, f.line - 1, f.col, f.line - 1, f.end_col, { f.replacement })
      rewritten = rewritten + 1
    end
  end

  notify.info(("migrate_effort: rewrote %d effort value(s)"):format(rewritten))
  if #items > 0 then
    vim.fn.setloclist(0, {}, " ", { title = ":Org migrate_effort", items = items })
    vim.cmd("lopen")
  end
end

return M
