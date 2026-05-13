-- :Org roam linkify — convert prose that matches a roam node title (or alias)
-- into an `[[id:UUID][match]]` link. Operates on:
--   * the word at cursor (default)
--   * the visual selection (range form)
--   * the entire current buffer (M.linkify_buffer / :Org roam linkify_buffer)
--
-- Matching rules:
--   * Whole-word, case-insensitive comparison against headline.title or any
--     alias (from the `aliases` table).
--   * The longest match at a position wins (helps multi-word titles).
--   * Already-bracketed text (inside `[[...]]`) is skipped.

local M = {}

local obuf = require("organ.buf")
-- Cached entries list from the most recent build. Invalidated by
-- `M.invalidate_index()` after the indexer commits a write batch, so
-- blink.cmp's per-keystroke `completion_items` call can reuse a single
-- DB scan instead of repeating one. Without this, the first insert-mode
-- entry against a cold sqlite cache freezes nvim for 5+ seconds.
local _index_cache = nil

-- Build a sorted list of { lower, title, id } from the DB. Title comes from
-- headlines table; aliases from the aliases table (joined on headline_id,
-- which is the same UUID as headlines.id).
function M._build_index_uncached()
  local query = require("organ.query")
  local entries = {}
  for _, r in ipairs(query.headlines({ has_id = true })) do
    if r.id and r.title and r.title ~= "" then
      entries[#entries + 1] = { lower = r.title:lower(), title = r.title, id = r.id }
    end
  end
  -- Aliases: walk the table directly — cheaper than per-row queries.
  local ok_rt, runtime = pcall(require, "organ.runtime")
  if ok_rt then
    local handle = runtime.db()
    local SQLITE_ROW = require("organ.db").SQLITE_ROW
    local stmt =
      handle:prepare("SELECT headline_id, alias FROM aliases WHERE headline_id NOT LIKE '%#L%'")
    if stmt then
      while stmt:step() == SQLITE_ROW do
        local id = stmt:column_text(0)
        local alias = stmt:column_text(1)
        if id and alias and alias ~= "" then
          entries[#entries + 1] = { lower = alias:lower(), title = alias, id = id }
        end
      end
      stmt:finalize()
    end
  end
  -- Longer keys win in greedy left-to-right matching; pre-sort descending.
  table.sort(entries, function(a, b)
    return #a.lower > #b.lower
  end)
  return entries
end

-- Memoized index lookup. Returns the cached entries until
-- `M.invalidate_index()` is called (typically after the indexer commits
-- a write batch). Callers can treat the return value as read-only.
function M.build_index()
  if _index_cache == nil then
    _index_cache = M._build_index_uncached()
  end
  return _index_cache
end

-- Drop the cached index. Next `build_index()` rebuilds from the DB.
function M.invalidate_index()
  _index_cache = nil
end

-- Replace matches in a single line. Returns (new_line, n_replacements).
-- Skips spans that are already inside `[[...]]`.
function M.linkify_line(line, entries)
  if line == "" then
    return line, 0
  end
  -- Identify protected ranges (inside `[[...]]`). Walk manually so we
  -- handle the two-bracket form `[[target][desc]]` (the simple regex
  -- `[[X]]` stops at the first `]`).
  local protected = {}
  do
    local pos = 1
    while pos <= #line do
      local lo = line:find("%[%[", pos)
      if not lo then
        break
      end
      local hi = line:find("%]%]", lo + 2)
      if not hi then
        break
      end
      protected[#protected + 1] = { lo, hi + 1 }
      pos = hi + 2
    end
  end
  local function is_protected(pos)
    for _, r in ipairs(protected) do
      if pos >= r[1] and pos <= r[2] then
        return true
      end
    end
    return false
  end
  local lower = line:lower()
  local n = 0
  local i = 1
  local out = {}
  while i <= #line do
    local c = line:sub(i, i)
    -- Word boundary heuristic: at start of string or after non-word char.
    local at_boundary = i == 1 or (line:sub(i - 1, i - 1):match("[%w_]") == nil)
    if at_boundary and not is_protected(i) then
      local hit
      for _, ent in ipairs(entries) do
        local end_pos = i + #ent.lower - 1
        if end_pos <= #line and lower:sub(i, end_pos) == ent.lower then
          local after = line:sub(end_pos + 1, end_pos + 1)
          if after == "" or after:match("[^%w_]") then
            hit = ent
            break
          end
        end
      end
      if hit then
        local matched_text = line:sub(i, i + #hit.lower - 1)
        out[#out + 1] = string.format("[[id:%s][%s]]", hit.id, matched_text)
        i = i + #hit.lower
        n = n + 1
      else
        out[#out + 1] = c
        i = i + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out), n
end

-- Linkify a contiguous range of lines [start_line, end_line] (1-based).
-- Returns the total replacement count.
function M.linkify_range(bufnr, start_line, end_line)
  local entries = M.build_index()
  if #entries == 0 then
    return 0
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local total = 0
  for i, ln in ipairs(lines) do
    local new, n = M.linkify_line(ln, entries)
    if n > 0 then
      lines[i] = new
      total = total + n
    end
  end
  if total > 0 then
    obuf.set_lines(bufnr, start_line - 1, end_line, lines)
  end
  return total
end

-- Linkify only the word at cursor (current line, current cursor column).
function M.linkify_cword(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  -- Find word boundaries around col.
  local s, e = col, col
  while s > 1 and line:sub(s - 1, s - 1):match("[%w_]") do
    s = s - 1
  end
  while e < #line and line:sub(e + 1, e + 1):match("[%w_]") do
    e = e + 1
  end
  local word = line:sub(s, e)
  if word == "" then
    return 0
  end
  local entries = M.build_index()
  local lower = word:lower()
  for _, ent in ipairs(entries) do
    if ent.lower == lower then
      local new = line:sub(1, s - 1)
        .. string.format("[[id:%s][%s]]", ent.id, word)
        .. line:sub(e + 1)
      obuf.set_lines(bufnr, row - 1, row, { new })
      return 1
    end
  end
  return 0
end

-- Linkify every line in the buffer. Returns total replacement count.
function M.linkify_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local n = vim.api.nvim_buf_line_count(bufnr)
  return M.linkify_range(bufnr, 1, n)
end

-- Completion source: candidates for the partial word the user is typing,
-- consumed by the blink.cmp / nvim-cmp adapters in lua/organ/complete/.
--
-- Returns up to 100 items; capped to bound work. Empty when query shorter
-- than min_chars (default 2) — keeps the popup quiet for one-letter tokens.
function M.completion_items(query, min_chars)
  query = query or ""
  min_chars = min_chars or 2
  if #query < min_chars then
    return {}
  end
  local q = query:lower()
  local out, seen = {}, {}
  for _, ent in ipairs(M.build_index()) do
    if ent.lower:find(q, 1, true) then
      local key = ent.id .. "|" .. ent.title
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = {
          label = ent.title,
          insertText = string.format("[[id:%s][%s]]", ent.id, ent.title),
          filterText = ent.title,
          kind = "Reference",
        }
        if #out >= 100 then
          break
        end
      end
    end
  end
  return out
end

-- Extract the word-fragment immediately before the cursor in `bufnr`.
-- Returns "" when not on a word, or when inside an existing `[[...]]`.
function M.cursor_partial(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local prefix = line:sub(1, col)
  -- Skip when the cursor sits inside an open `[[`. The trigger-based source
  -- (organ_link) handles those; we don't want to double-fire.
  local last_open = prefix:reverse():find("%]%[") -- "][" in original
  local last_open2 = prefix:reverse():find("%[%[") -- "[[" in original
  if last_open2 and (not last_open or last_open2 < last_open) then
    return ""
  end
  -- Walk back from cursor while still on a word char.
  local s = col
  while s > 0 and prefix:sub(s, s):match("[%w_]") do
    s = s - 1
  end
  return prefix:sub(s + 1, col)
end

return M
