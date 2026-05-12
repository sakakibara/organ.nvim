-- Hide leading stars on headings (Emacs `org-hide-leading-stars`).
--
-- Renders `*** Foo` as `  * Foo` by concealing the leading N-1 stars
-- with a space-replacement conceal extmark. The trailing star (the
-- one immediately before the title) stays visible so the depth marker
-- isn't lost entirely.
--
-- Off by default; opt in via `config.stars.hide = true`.
--
-- Runs as an `organ.decoration` provider: a per-buffer row cache maps
-- row -> leading-star count, rebuilt on `on_lines` via a single regex
-- per affected line.  Initial population is synchronous; subsequent
-- edits debounce 150ms so per-keystroke rebuilds don't run when the
-- user is mid-burst.  Concealment is visible only when
-- `conceallevel >= 2` -- `attach()` bumps it to 2 (restored by detach).

local M = {}

local NS = vim.api.nvim_create_namespace("organ_stars_hide")

-- Per-buffer row cache: cache_by_buf[bufnr][row] = leading-star count.
-- Rows that aren't headlines are absent.
local cache_by_buf = {}

-- Trailing-debounce timers for the on_lines rebuild path, keyed by
-- bufnr.  Matches the conceal provider's pattern: even though the
-- per-row regex is trivial, coalescing edits avoids running on every
-- keystroke during a burst.
local rebuild_timers = {}
local REBUILD_DEBOUNCE_MS = 150

local function cancel_rebuild_timer(bufnr)
  local t = rebuild_timers[bufnr]
  if not t then
    return
  end
  rebuild_timers[bufnr] = nil
  pcall(t.stop, t)
  pcall(t.close, t)
end

local function build_cache(bufnr)
  local rows = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return rows
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return rows
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local stars = line:match("^(%*+)%s")
    if stars then
      rows[i - 1] = #stars
    end
  end
  return rows
end

-- Place all cached marks for `bufnr` as non-ephemeral extmarks.  Used
-- by `_apply` (test-facing) for an immediate visible refresh independent
-- of frame dispatch.
local function place_marks(bufnr, rows)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  for row, n in pairs(rows) do
    if n > 1 then
      for i = 0, n - 2 do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, i, {
          end_col = i + 1,
          conceal = " ",
        })
      end
    end
  end
end

local function schedule_rebuild(bufnr)
  cancel_rebuild_timer(bufnr)
  local t = vim.uv.new_timer()
  if not t then
    cache_by_buf[bufnr] = build_cache(bufnr)
    return
  end
  rebuild_timers[bufnr] = t
  t:start(REBUILD_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    rebuild_timers[bufnr] = nil
    pcall(t.stop, t)
    pcall(t.close, t)
    if vim.api.nvim_buf_is_valid(bufnr) then
      cache_by_buf[bufnr] = build_cache(bufnr)
    end
  end))
end

require("organ.decoration").register({
  name = "stars",
  ns = NS,
  enabled = function(_bufnr)
    local cfg = require("organ").config
    return (cfg.stars or {}).hide == true
  end,
  on_lines = function(bufnr, _first, _last_old, _last_new)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if cache_by_buf[bufnr] == nil then
      cache_by_buf[bufnr] = build_cache(bufnr)
      return
    end
    schedule_rebuild(bufnr)
  end,
  on_line = function(bufnr, winid, row)
    if vim.wo[winid].conceallevel == 0 then
      return
    end
    local rows = cache_by_buf[bufnr]
    if not rows then
      return
    end
    local n = rows[row]
    if not n or n < 2 then
      return
    end
    for i = 0, n - 2 do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, i, {
        end_col = i + 1,
        conceal = " ",
        ephemeral = true,
      })
    end
  end,
})

-- Per-window saved conceallevel so detach() restores rather than nukes.
M._saved_conceallevel = M._saved_conceallevel or {}

-- Test-facing + ftplugin entrypoint.  Bumps the window's conceallevel
-- to 2 (saving the previous value), attaches the decoration provider
-- to the buffer, and synchronously applies non-ephemeral extmarks so
-- callers that assert via `nvim_buf_get_extmarks` see them without
-- waiting for a frame.
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] == nil then
    M._saved_conceallevel[winid] = vim.wo.conceallevel
  end
  if vim.wo.conceallevel < 2 then
    vim.wo.conceallevel = 2
  end
  pcall(function()
    require("organ.decoration").attach(bufnr)
  end)
  M._apply(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  cache_by_buf[bufnr] = nil
  cancel_rebuild_timer(bufnr)
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] ~= nil then
    vim.wo.conceallevel = M._saved_conceallevel[winid]
    M._saved_conceallevel[winid] = nil
  end
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { limit = 1 })
  if #marks > 0 then
    M.detach(bufnr)
    return false
  end
  M.attach(bufnr)
  return true
end

-- Test-facing: rebuild the cache + place non-ephemeral extmarks now.
-- Ephemeral marks from on_line live only for the rendered frame;
-- assertions via nvim_buf_get_extmarks need real extmarks.
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local rows = build_cache(bufnr)
  cache_by_buf[bufnr] = rows
  place_marks(bufnr, rows)
end

return M
