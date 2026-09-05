-- Per-buffer cache of headline positions, invalidated by changedtick.
--
-- The Emacs analogue is `org-element-cache`, which incrementally caches
-- parsed elements at byte ranges so motions and structural ops on huge
-- files don't re-walk the whole buffer. Our equivalent is simpler: we
-- keep a sorted list of `{ line, level }` per buffer and rebuild the
-- whole list when the buffer's changedtick advances. Rebuild is one
-- linear scan; lookups are binary searches. For a 10k-line file with
-- 500 headlines, motions go from O(N) to O(log H).
--
-- Public API:
--   M.headlines(bufnr)                       -> { { line, level }, ... }
--   M.containing(bufnr, line)                -> entry | nil
--   M.containing_index(bufnr, line)          -> index | nil
--   M.subtree_end(bufnr, line)               -> 1-based last line
--   M.next_headline(bufnr, line)             -> entry | nil
--   M.prev_headline(bufnr, line)             -> entry | nil
--   M.outline_path(bufnr, line)              -> { ancestor titles, root → leaf }
--   M.invalidate(bufnr)                      -> drop cache for buffer
--   M.stats()                                -> { hits, misses, rebuilds }

local M = {}

local _cache = {} -- bufnr -> { tick, entries = { {line, level, title} } }
local _stats = { hits = 0, misses = 0, rebuilds = 0 }

local function parse_line(text)
  local stars, rest = text:match("^(%*+) +(.*)$")
  if stars then
    return #stars, rest
  end
end

local function rebuild(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local entries = {}
  for i, ln in ipairs(lines) do
    local level, title = parse_line(ln)
    if level then
      entries[#entries + 1] = { line = i, level = level, title = title }
    end
  end
  _stats.rebuilds = _stats.rebuilds + 1
  return entries
end

local function ensure(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = _cache[bufnr]
  if c and c.tick == tick then
    _stats.hits = _stats.hits + 1
    return c.entries
  end
  _stats.misses = _stats.misses + 1
  c = { tick = tick, entries = rebuild(bufnr) }
  _cache[bufnr] = c
  return c.entries
end

function M.headlines(bufnr)
  return ensure(bufnr) or {}
end

-- Largest index whose entry.line <= line. nil when no such entry.
local function bsearch_le(entries, line)
  local lo, hi = 1, #entries
  local result = nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if entries[mid].line <= line then
      result = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end
  return result
end

function M.containing_index(bufnr, line)
  local entries = ensure(bufnr)
  if not entries then
    return nil
  end
  return bsearch_le(entries, line)
end

function M.containing(bufnr, line)
  local entries = ensure(bufnr)
  if not entries then
    return nil
  end
  local idx = bsearch_le(entries, line)
  return idx and entries[idx] or nil
end

function M.subtree_end(bufnr, line)
  local entries = ensure(bufnr)
  if not entries then
    return vim.api.nvim_buf_line_count(bufnr or 0)
  end
  local idx = bsearch_le(entries, line)
  if not idx then
    return vim.api.nvim_buf_line_count(bufnr or 0)
  end
  local hl_level = entries[idx].level
  for j = idx + 1, #entries do
    if entries[j].level <= hl_level then
      return entries[j].line - 1
    end
  end
  return vim.api.nvim_buf_line_count(bufnr or 0)
end

function M.next_headline(bufnr, line)
  local entries = ensure(bufnr)
  if not entries then
    return nil
  end
  local idx = bsearch_le(entries, line)
  -- bsearch returns the headline at-or-before `line`. The "next" is the
  -- entry after the cursor's current entry, OR if cursor is below all
  -- headlines, nothing.
  if not idx then
    return entries[1]
  end
  if entries[idx].line == line then
    return entries[idx + 1]
  end
  return entries[idx + 1]
end

function M.prev_headline(bufnr, line)
  local entries = ensure(bufnr)
  if not entries then
    return nil
  end
  local idx = bsearch_le(entries, line)
  if not idx then
    return nil
  end
  if entries[idx].line == line then
    return entries[idx - 1]
  end
  return entries[idx]
end

function M.outline_path(bufnr, line)
  local entries = ensure(bufnr)
  if not entries then
    return {}
  end
  local idx = bsearch_le(entries, line)
  if not idx then
    return {}
  end
  local path = {}
  local current_level = entries[idx].level + 1
  for j = idx, 1, -1 do
    if entries[j].level < current_level then
      path[#path + 1] = entries[j].title
      current_level = entries[j].level
      if current_level == 1 then
        break
      end
    end
  end
  -- Reverse to root → leaf order.
  local n = #path
  for i = 1, math.floor(n / 2) do
    path[i], path[n - i + 1] = path[n - i + 1], path[i]
  end
  return path
end

function M.invalidate(bufnr)
  _cache[bufnr or vim.api.nvim_get_current_buf()] = nil
end

function M.stats()
  return vim.deepcopy(_stats)
end
function M._reset_stats()
  _stats = { hits = 0, misses = 0, rebuilds = 0 }
end

-- Drop cache when buffer is wiped.
local _aug = vim.api.nvim_create_augroup("organ.element_cache", { clear = true })
require("organ.errors").autocmd("BufWipeout", {
  group = _aug,
  callback = function(ev)
    _cache[ev.buf] = nil
  end,
})

return M
