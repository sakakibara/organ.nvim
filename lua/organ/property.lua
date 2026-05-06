local M = {}

local element = require("organ.element")

-- Find the headline that contains line `line` (1-based). Returns 1-based hl line or nil.
local function find_headline(bufnr, line)
  local h = element.headline_at(bufnr, line - 1)
  if h then
    return h.line_start + 1
  end
  return nil
end

-- Skip planning lines after headline; returns 1-based line where any drawer
-- (or body content) would begin.  Delegates to `element.planning_end_line`
-- which uses the `planning` TS node when available.
local function planning_end(bufnr, hl_line)
  return element.planning_end_line(bufnr, hl_line - 1)
end

-- Returns { start_line, end_line } or nil.  Delegates to
-- `element.property_drawer_range` (TS-first).
local function find_property_drawer(bufnr, hl_line)
  return element.property_drawer_range(bufnr, hl_line - 1)
end

local function parse_property_line(text)
  local key, value = text:match("^%s*:([%w%-_]+):%s*(.-)%s*$")
  if not key then
    return nil
  end
  return key, value
end

function M.list(bufnr, line)
  local hl = find_headline(bufnr, line)
  if not hl then
    return nil
  end
  local drawer = find_property_drawer(bufnr, hl)
  if not drawer then
    return {}
  end
  local entries = {}
  for i = drawer.start_line + 1, drawer.end_line - 1 do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    local k, v = parse_property_line(txt)
    if k then
      entries[#entries + 1] = { key = k, value = v }
    end
  end
  return entries
end

function M.set(bufnr, line, key, value)
  if type(key) ~= "string" or key == "" or key:find(":") then
    return ("invalid property key '%s'"):format(tostring(key))
  end
  -- Property values cannot contain newlines — they'd split the entry across
  -- multiple lines and break the property_drawer parse on next read.
  if type(value) == "string" and value:find("[\r\n]") then
    return ("invalid value for '%s': contains newline"):format(key)
  end
  local hl = find_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  local drawer = find_property_drawer(bufnr, hl)
  if drawer then
    -- Look for existing key.
    for i = drawer.start_line + 1, drawer.end_line - 1 do
      local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
      local k = parse_property_line(txt)
      if k == key then
        local new = ":" .. key .. ": " .. value
        vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
        return nil
      end
    end
    -- Insert before :END:.
    local new = ":" .. key .. ": " .. value
    vim.api.nvim_buf_set_lines(bufnr, drawer.end_line - 1, drawer.end_line - 1, false, { new })
    return nil
  end
  -- No drawer: insert at planning_end.
  local insert_at = planning_end(bufnr, hl)
  local new_drawer = {
    ":PROPERTIES:",
    ":" .. key .. ": " .. value,
    ":END:",
  }
  vim.api.nvim_buf_set_lines(bufnr, insert_at - 1, insert_at - 1, false, new_drawer)
  return nil
end

function M.delete(bufnr, line, key)
  local hl = find_headline(bufnr, line)
  if not hl then
    return ("property '%s' not set"):format(key)
  end
  local drawer = find_property_drawer(bufnr, hl)
  if not drawer then
    return ("property '%s' not set"):format(key)
  end
  -- Find the key line.
  local key_line = nil
  for i = drawer.start_line + 1, drawer.end_line - 1 do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    local k = parse_property_line(txt)
    if k == key then
      key_line = i
      break
    end
  end
  if not key_line then
    return ("property '%s' not set"):format(key)
  end
  -- Delete the key line.
  vim.api.nvim_buf_set_lines(bufnr, key_line - 1, key_line, false, {})
  -- Re-check drawer: if now empty (start_line + 1 == end_line - 1 originally meant 1 entry;
  -- after deletion, drawer's body has 0 lines).
  local new_end = drawer.end_line - 1 -- shift up by 1 due to delete
  local body_size = new_end - drawer.start_line - 1
  if body_size == 0 then
    -- Remove the entire drawer.
    vim.api.nvim_buf_set_lines(bufnr, drawer.start_line - 1, new_end, false, {})
  end
  return nil
end

local function _split(s)
  local out = {}
  for v in tostring(s):gmatch("%S+") do
    out[#out + 1] = v
  end
  return out
end

-- Discover allowed values for `key` from (in priority order):
--   1. The headline's own :KEY_ALL: property entry.
--   2. Any ancestor headline's :KEY_ALL: (closest wins).
--   3. File-level `#+PROPERTY: KEY_ALL value1 value2 …` keyword.
-- Returns a list of allowed string values, or nil when unconstrained.
function M.allowed_values(bufnr, hl_line, key)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local target = key .. "_ALL"

  -- Walk up the ancestor chain inspecting each headline's drawer.
  local function drawer_value(hl_idx)
    local i = hl_idx + 1
    while
      i <= #lines
      and (
        lines[i]:match("^%s*SCHEDULED:")
        or lines[i]:match("^%s*DEADLINE:")
        or lines[i]:match("^%s*CLOSED:")
        or lines[i]:match("^%s*$")
      )
    do
      i = i + 1
    end
    if not (lines[i] and lines[i]:match("^%s*:PROPERTIES:")) then
      return nil
    end
    i = i + 1
    while i <= #lines and not lines[i]:match("^%s*:END:") do
      local k, v = lines[i]:match("^%s*:([%w_]+):%s*(.-)%s*$")
      if k == target then
        return v
      end
      i = i + 1
    end
    return nil
  end

  local v = drawer_value(hl_line)
  if v then
    return _split(v)
  end

  -- Walk up: find ancestors by counting stars.
  local stars = (lines[hl_line] or ""):match("^(%*+)") or ""
  local lvl = #stars
  for i = hl_line - 1, 1, -1 do
    local s = (lines[i] or ""):match("^(%*+)%s")
    if s and #s < lvl then
      v = drawer_value(i)
      if v then
        return _split(v)
      end
      lvl = #s
      if lvl == 1 then
        break
      end
    end
  end

  -- File-level `#+PROPERTY: KEY_ALL ...`.
  for _, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      break
    end
    local k, val = ln:match("^%s*#%+PROPERTY:%s+(%S+)%s+(.+)%s*$")
    if k == target and val then
      return _split(val)
    end
  end
  return nil
end

M._split = _split

function M.set_interactive(bufnr, line)
  local hl = find_headline(bufnr, line)
  if not hl then
    require("organ.notify").warn("not on a headline")
    return
  end
  vim.ui.input({ prompt = "Property key: " }, function(key)
    if not key or key == "" then
      return
    end
    local existing = M.list(bufnr, hl) or {}
    local default = ""
    for _, p in ipairs(existing) do
      if p.key == key then
        default = p.value
        break
      end
    end
    -- If the key has an allowed-values list, present a selector instead of
    -- free-form input.
    local allowed = M.allowed_values(bufnr, hl, key)
    local function commit(value)
      if value == nil then
        return
      end
      local err = M.set(bufnr, hl, key, value)
      if err then
        require("organ.notify").error(err)
      end
    end
    if allowed and #allowed > 0 then
      vim.ui.select(allowed, { prompt = key .. " (allowed values):" }, commit)
    else
      vim.ui.input({ prompt = "Value for " .. key .. ": ", default = default }, commit)
    end
  end)
end

-- :Org set_effort — interactive effort setter constrained by `:EFFORT_ALL:`
-- (per-headline / inherited) or file-level `#+PROPERTY: EFFORT_ALL …`.
-- Falls back to free-form input when no allowed values are configured.
function M.set_effort_interactive(bufnr, line)
  local hl = find_headline(bufnr, line)
  if not hl then
    require("organ.notify").warn("not on a headline")
    return
  end
  local allowed = M.allowed_values(bufnr, hl, "EFFORT")
  local function commit(value)
    if value == nil or value == "" then
      return
    end
    local err = M.set(bufnr, hl, "EFFORT", value)
    if err then
      require("organ.notify").error(err)
    end
  end
  if allowed and #allowed > 0 then
    vim.ui.select(allowed, { prompt = "Effort:" }, commit)
  else
    vim.ui.input({ prompt = "Effort: " }, commit)
  end
end

function M.delete_interactive(bufnr, line)
  local hl = find_headline(bufnr, line)
  if not hl then
    require("organ.notify").warn("not on a headline")
    return
  end
  local existing = M.list(bufnr, hl) or {}
  if #existing == 0 then
    require("organ.notify").warn("no properties on this headline")
    return
  end
  local keys = {}
  for _, p in ipairs(existing) do
    keys[#keys + 1] = p.key
  end
  vim.ui.select(keys, { prompt = "Delete property:" }, function(choice)
    if not choice then
      return
    end
    local err = M.delete(bufnr, hl, choice)
    if err then
      require("organ.notify").error(err)
    end
  end)
end

local function bufnr_line()
  return vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1]
end

M.commands = {
  set_property = {
    fn = function()
      local bufnr, line = bufnr_line()
      M.set_interactive(bufnr, line)
    end,
    desc = "Set or update a property on the current headline",
  },
  delete_property = {
    fn = function()
      local bufnr, line = bufnr_line()
      M.delete_interactive(bufnr, line)
    end,
    desc = "Delete a property from the current headline",
  },
  set_effort = {
    fn = function()
      local bufnr, line = bufnr_line()
      M.set_effort_interactive(bufnr, line)
    end,
    desc = "Set EFFORT property (constrained by :EFFORT_ALL: when configured)",
  },
}

return M
