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
-- Runs as an `organ.decoration` provider: `on_win` queries tree-sitter
-- for headlines in the visible range and scans the same range for list
-- markers and checkboxes (the org grammar doesn't surface those
-- uniformly as nodes, so a flat byte-prefix scan is the right tool);
-- results land in a module-local frame-row map.  `on_line` reads the
-- map and emits ephemeral conceal extmarks for the current row.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_bullets")

-- org-modern's default cycle. Repeats for levels > 4.
local DEFAULT_GLYPHS = { "◉", "○", "◈", "◇" }

local function bcfg(bufnr, path)
  return require("organ.buf_config").read(bufnr, path)
end

local function get_glyphs(bufnr)
  local b = bcfg(bufnr, "modern.bullets")
  if type(b) == "table" and type(b.glyphs) == "table" and #b.glyphs > 0 then
    return b.glyphs
  end
  return DEFAULT_GLYPHS
end

-- Configurable additional symbols for list bullets and checkboxes.
-- Mirrors org-bullets.nvim's `symbols.list` / `symbols.checkboxes`.
local function get_list_glyph(bufnr)
  local b = bcfg(bufnr, "modern.bullets")
  if type(b) == "table" and b.list ~= nil then
    return b.list
  end
  return "•" -- matches org-bullets default
end

local function get_checkbox_glyphs(bufnr)
  local b = bcfg(bufnr, "modern.bullets")
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

-- Per-window saved conceallevel so detach() restores rather than nukes.
M._saved_conceallevel = M._saved_conceallevel or {}

-- Frame-local row map: frame_map[row] = { { col, end_col, conceal }, ... }.
-- Reset at the start of every on_win call; read by on_line for the
-- same frame.  No per-buffer keying: only one window's on_win runs
-- before its on_line callbacks for the same frame.
local frame_map = {}

M._frame_map = function()
  return frame_map
end

local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not bcfg(bufnr, "modern.bullets") then
    return
  end

  local function push(row, col, end_col, conceal, hl)
    if row < topline or row > botline then
      return
    end
    frame_map[row] = frame_map[row] or {}
    frame_map[row][#frame_map[row] + 1] =
      { col = col, end_col = end_col, conceal = conceal, hl = hl }
  end

  -- Headline stars: tree-sitter `(headline) @h` captures, scoped to
  -- the visible range.  Tree is parsed once per buffer per redraw by
  -- organ.decoration; we just query the cached tree here.
  do
    local tree = require("organ.decoration").get_tree(bufnr)
    local q = get_query()
    if tree and q then
      local glyphs = get_glyphs(bufnr)
      for _, node in q:iter_captures(tree:root(), bufnr, topline, botline + 1) do
        local sr, sc = node:start()
        if sr >= topline and sr <= botline then
          local ok_line, line = pcall(vim.api.nvim_buf_get_lines, bufnr, sr, sr + 1, false)
          if ok_line and line and line[1] then
            local stars = line[1]:match("^(%*+)") or ""
            local n = #stars
            if n >= 1 then
              for i = 0, n - 2 do
                push(sr, sc + i, sc + i + 1, " ")
              end
              local glyph = glyphs[((n - 1) % #glyphs) + 1]
              -- Color the bullet like the heading title (matches the
              -- foldtext bullet); the concealed leading stars stay blank.
              push(sr, sc + n - 1, sc + n, glyph, require("organ.highlights").heading_title_hl(n))
            end
          end
        end
      end
    end
  end

  -- List-item bullets and checkboxes: scan visible lines for
  -- `<indent>- ` / `<indent>+ ` markers and `[ ]`/`[X]`/`[x]`/`[-]`
  -- checkboxes inside list items.  The org grammar doesn't expose
  -- marker / checkbox nodes uniformly, so a line scan is more direct
  -- than a tree walk here.
  local cb_glyphs = get_checkbox_glyphs(bufnr)
  local list_glyph = get_list_glyph(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, topline, botline + 1, false)
  for i, line in ipairs(lines) do
    local row = topline + i - 1
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
end

local function on_line(bufnr, _winid, row)
  local entries = frame_map[row]
  if not entries then
    return
  end
  for _, e in ipairs(entries) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, e.col, {
      end_col = e.end_col,
      conceal = e.conceal,
      hl_group = e.hl,
      ephemeral = true,
    })
  end
end

require("organ.decoration").register({
  name = "modern_bullets",
  ns = NS,
  enabled = function(bufnr)
    return bcfg(bufnr, "modern.bullets") and true or false
  end,
  on_win = on_win,
  on_line = on_line,
})

-- Test-facing + ftplugin entrypoint.  Drive on_win across the full
-- buffer and place non-ephemeral extmarks so callers asserting via
-- `nvim_buf_get_extmarks` see them without waiting for a frame.
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  on_win(bufnr, 0, 0, n - 1)
  for row, entries in pairs(frame_map) do
    for _, e in ipairs(entries) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, e.col, {
        end_col = e.end_col,
        conceal = e.conceal,
        hl_group = e.hl,
      })
    end
  end
end

-- Display string that replaces a headline's leading `level`-star block:
-- (level-1) spaces + the per-level glyph.  A closed fold renders foldtext
-- instead of the real line, so the on_line conceal never reaches it; the
-- foldtext renderer calls this to show the same bullet on a folded head.
function M.star_display(bufnr, level)
  if not level or level < 1 then
    return nil
  end
  local glyphs = get_glyphs(bufnr)
  local glyph = glyphs[((level - 1) % #glyphs) + 1]
  return string.rep(" ", level - 1) .. glyph
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
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] ~= nil then
    vim.wo.conceallevel = M._saved_conceallevel[winid]
    M._saved_conceallevel[winid] = nil
  end
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Drive via buf_config so the reapply hook handles attach / detach.
  local on = require("organ.buf_config").toggle(bufnr, "modern.bullets")
  return on and true or false
end

-- Reapply hook: react to live `modern.bullets` flips on this buffer.
require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local want = bcfg(bufnr, "modern.bullets") and true or false
  if want then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
