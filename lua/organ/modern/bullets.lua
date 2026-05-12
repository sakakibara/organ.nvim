-- Per-level headline bullets (org-modern's `org-modern-star`).
--
-- Replaces the trailing `*` of each headline's leading-star block
-- with a per-level glyph (cycled through a configurable list), and
-- conceals the leading N-1 stars as spaces. So:
--
--   *** Foo   ->     ◈ Foo     (with 2 spaces of indent)
--   ** Bar    ->     ○ Bar     (with 1 space)
--   * Baz     ->     ◉ Baz
--
-- Self-contained: do NOT combine with `stars.lua` -- both touch the
-- same byte range and the last-applied conceal wins (non-deterministic).
-- Users should pick one. The default config wires this in via
-- `modern.bullets = true`; `stars.hide = true` is the alternative.
--
-- Also handles list-item bullet decoration (`- foo` -> `• foo`) and
-- checkbox glyphs (`[ ]` -> `˟`, `[X]` -> `✓`, `[-]` -> `▣`) for
-- parity with org-bullets.nvim.
--
-- Runs as an `organ.decoration` provider: `on_lines` rebuilds a per-
-- buffer row cache (tree-sitter headline walk + line scan for list
-- markers / checkboxes), and `on_line` emits ephemeral conceal
-- extmarks for the visible row.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_bullets")

-- org-modern's default cycle. Repeats for levels > 4.
local DEFAULT_GLYPHS = { "◉", "○", "◈", "◇" }

local function get_glyphs()
  local cfg = (require("organ").config.modern or {})
  local b = cfg.bullets
  if type(b) == "table" and type(b.glyphs) == "table" and #b.glyphs > 0 then
    return b.glyphs
  end
  return DEFAULT_GLYPHS
end

-- Configurable additional symbols for list bullets and checkboxes.
-- Mirrors org-bullets.nvim's `symbols.list` / `symbols.checkboxes`.
local function get_list_glyph()
  local cfg = (require("organ").config.modern or {})
  local b = cfg.bullets
  if type(b) == "table" and b.list ~= nil then
    return b.list
  end
  return "•" -- matches org-bullets default
end

local function get_checkbox_glyphs()
  local cfg = (require("organ").config.modern or {})
  local b = cfg.bullets
  local cb = (type(b) == "table" and b.checkboxes) or {}
  return {
    todo = cb.todo or "˟",
    done = cb.done or "✓",
    half = cb.half or "▣",
  }
end

-- Cached headline query (parsed once per session).
local _q
local function get_query()
  if _q then
    return _q
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, "org", "(headline) @h")
  if ok then
    _q = parsed
  end
  return _q
end

-- Per-buffer row cache: cache_by_buf[bufnr][row] = { entry, ... } where
-- each entry is { col = N, end_col = N, conceal = "<char>" }.  Rows that
-- have no concealment are absent.
local cache_by_buf = {}

-- Build the per-row cache by walking the headline tree (tree-sitter)
-- for star concealment, then scanning lines for list bullets and
-- checkboxes.  Same logic as the pre-migration apply(), bucketed by
-- row for the on_line dispatcher.
local function build_cache(bufnr)
  local rows = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return rows
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return rows
  end

  local function push(row, col, end_col, conceal)
    rows[row] = rows[row] or {}
    rows[row][#rows[row] + 1] = { col = col, end_col = end_col, conceal = conceal }
  end

  -- Headline stars: walk `(headline)` nodes via tree-sitter.
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if ok_parser and parser then
    local tree = (parser:parse() or {})[1]
    local q = get_query()
    if tree and q then
      local glyphs = get_glyphs()
      for _, node in q:iter_captures(tree:root(), bufnr, 0, -1) do
        local sr, sc = node:start()
        local ok_line, line = pcall(vim.api.nvim_buf_get_lines, bufnr, sr, sr + 1, false)
        if ok_line and line and line[1] then
          local stars = line[1]:match("^(%*+)") or ""
          local n = #stars
          if n >= 1 then
            -- Conceal leading N-1 stars as spaces.
            for i = 0, n - 2 do
              push(sr, sc + i, sc + i + 1, " ")
            end
            -- Conceal the trailing star with a level-specific glyph.
            local glyph = glyphs[((n - 1) % #glyphs) + 1]
            push(sr, sc + n - 1, sc + n, glyph)
          end
        end
      end
    end
  end

  -- List-item bullets and checkboxes: scan all lines for `<indent>- ` /
  -- `<indent>+ ` markers and `[ ]`/`[X]`/`[x]`/`[-]` checkboxes inside
  -- list items.  The org grammar doesn't expose marker / checkbox
  -- nodes uniformly, so a line scan is more direct than a tree walk
  -- here.  (The headline path above IS tree-sitter; this is a fallback
  -- for shapes the grammar doesn't surface as nodes.)
  local cb_glyphs = get_checkbox_glyphs()
  local list_glyph = get_list_glyph()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local row = i - 1
    local indent, marker = line:match("^(%s*)([%-%+])%s")
    if marker then
      local col = #indent
      push(row, col, col + 1, list_glyph)
    end
    -- Checkbox: `[ ]` / `[X]` / `[x]` / `[-]` somewhere on the line,
    -- but only inside list items (line that has a list marker OR is a
    -- numbered list `N.`/`N)`).  Checkboxes on plain text are left
    -- alone.
    if marker or line:match("^%s*%d+[%.%)]%s") then
      local s, e, ch = line:find("%[([ xX%-])%]")
      if s and ch then
        local g
        if ch == "X" or ch == "x" then
          g = cb_glyphs.done
        elseif ch == "-" then
          g = cb_glyphs.half
        else
          g = cb_glyphs.todo
        end
        push(row, s - 1, e, g)
      end
    end
  end

  return rows
end

-- Emit all cached extmarks for one row.  Shared between the ephemeral
-- on_line path and the non-ephemeral _apply path; the caller sets
-- `ephemeral`.
local function place_row(bufnr, row, entries, ephemeral)
  for _, e in ipairs(entries) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, e.col, {
      end_col = e.end_col,
      conceal = e.conceal,
      ephemeral = ephemeral or nil,
    })
  end
end

require("organ.decoration").register({
  name = "modern_bullets",
  ns = NS,
  enabled = function(_bufnr)
    local cfg = require("organ").config
    return (cfg.modern or {}).bullets and true or false
  end,
  on_lines = function(bufnr, _first, _last_old, _last_new)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    -- Full rebuild: tree-sitter's incremental parse keeps the cost
    -- bounded.  Range-bounded walks are a future optimization.
    cache_by_buf[bufnr] = build_cache(bufnr)
  end,
  on_line = function(bufnr, _winid, row)
    local rows = cache_by_buf[bufnr]
    if not rows then
      return
    end
    local entries = rows[row]
    if not entries then
      return
    end
    place_row(bufnr, row, entries, true)
  end,
})

-- Per-window saved conceallevel so detach() restores rather than nukes.
M._saved_conceallevel = M._saved_conceallevel or {}

-- Test-facing + ftplugin entrypoint.  Rebuild the cache + place non-
-- ephemeral extmarks so callers asserting via `nvim_buf_get_extmarks`
-- see them without waiting for a frame.
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local rows = build_cache(bufnr)
  cache_by_buf[bufnr] = rows
  for row, entries in pairs(rows) do
    place_row(bufnr, row, entries, false)
  end
end

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

return M
