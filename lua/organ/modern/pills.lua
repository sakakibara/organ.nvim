-- TODO + timestamp pill rendering (org-modern's pill style).
--
-- Approximates Emacs org-modern's `:inverse-video t` pill effect: the
-- existing @org.todo.* and @org.timestamp groups (which carry fg) get
-- `reverse = true` overlaid via fresh hl groups, so the keyword bytes
-- render as a solid block of color (the fg becomes the bg).
--
-- This module is purely cosmetic -- no buffer text changes, no conceals.
-- Highlight groups + extmark hl_group overlays.
--
-- Runs as an `organ.decoration` provider: `on_win` queries tree-sitter
-- for the visible window range, walks the org tree for headline TODO
-- keywords and title-byte timestamp shapes, and walks injected
-- org_inline trees for timestamp nodes; results land in a module-local
-- frame-row map.  `on_line` reads the map and emits ephemeral hl
-- extmarks for the current row.  Tree-sitter is the source of truth:
-- the inline-grammar timestamp nodes correctly exclude code blocks,
-- drawers, and other inert contexts where a `<...>` / `[...]` regex
-- would false-positive; the title-bytes scan is bounded to the title
-- node range, so it inherits the same node-level scoping.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_pills")

-- Per-window saved conceallevel (we DON'T modify it for pills, but
-- keep the hook symmetric with bullets/blocks).
M._saved_conceallevel = M._saved_conceallevel or {}

local PILL_KEYWORDS = {
  "todo",
  "next",
  "wait",
  "waiting",
  "hold",
  "proj",
  "started",
  "done",
  "cancelled",
  "canceled",
  "closed",
}

-- Badge body + cap groups per keyword and for timestamps, via the shared
-- badge primitive which resolves the color and applies reverse without link
-- (nvim_set_hl drops gui attributes when link is present).
local function register_pill_highlights()
  local badge = require("organ.modern.badge")
  for _, kw in ipairs(PILL_KEYWORDS) do
    badge.groups("pill." .. kw, "@org.todo." .. kw)
  end
  badge.groups("pill.timestamp", "@org.timestamp")
end

-- Pill hl groups depend on live colors; re-derive them on colorscheme
-- change (deferred to the next redraw so organ.highlights has already
-- re-set the @org.todo.* groups this ColorScheme fires).
local _pill_hl_dirty = true
local function ensure_pill_highlights()
  if not _pill_hl_dirty then
    return
  end
  register_pill_highlights()
  _pill_hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_pills_hl", { clear = true }),
  callback = function()
    _pill_hl_dirty = true
  end,
})

-- Cached headline + timestamp queries (parsed once per session).
local _q_headline
local function get_headline_query()
  if _q_headline then
    return _q_headline
  end
  -- Capture todo and title separately on the same headline_line so we
  -- can pill the TODO keyword AND scan the title bytes for timestamp
  -- shapes (the inline grammar isn't injected into the title, so
  -- `<...>` / `[...]` inside a heading title is plain text from the
  -- block grammar's point of view).
  local ok, parsed = pcall(
    vim.treesitter.query.parse,
    "org",
    [[
      (headline_line todo: (todo) @kw)
      (headline_line title: (title) @title)
    ]]
  )
  if ok then
    _q_headline = parsed
  end
  return _q_headline
end

-- Active + inactive + ranged timestamps, all from the injected
-- org_inline grammar.
local _q_timestamp
local function get_timestamp_query()
  if _q_timestamp then
    return _q_timestamp
  end
  local ok, parsed = pcall(
    vim.treesitter.query.parse,
    "org_inline",
    [[
      (timestamp_active) @ts
      (timestamp_inactive) @ts
      (timestamp_range_active) @ts
      (timestamp_range_inactive) @ts
    ]]
  )
  if ok then
    _q_timestamp = parsed
  end
  return _q_timestamp
end

-- TODO keyword sequence from config, used to pick the per-keyword
-- pill hl group.  Recomputed on each on_win so config changes take
-- effect without a session restart.
local function todo_keywords_set(bufnr)
  local seq = require("organ.buf_config").read(bufnr, "todo.sequence") or {}
  local set = {}
  for _, k in ipairs(seq) do
    if k ~= "|" then
      set[k] = true
    end
  end
  return set
end

-- Frame-local row map: frame_map[row] = { entry, ... }.  An entry is
-- { col, end_col, hl_group } for a timestamp box; a keyword pill also
-- carries cap_hl so emit() can pass rounded caps via glyphs.get.  Reset
-- each on_win; read by on_line for the same frame.
local frame_map = {}

-- Place one frame entry's extmarks via the badge primitive: reversed body
-- over the range, plus INLINE caps at the range boundaries for keyword
-- entries.  Box mode (modern.pill_caps = false) forces empty caps.
local function emit(bufnr, row, e, ephemeral)
  local badge = require("organ.modern.badge")
  local glyphs = require("organ.modern.glyphs")
  local left, right = "", ""
  if e.cap_hl then
    left = glyphs.get("pill.cap.left", bufnr)
    right = glyphs.get("pill.cap.right", bufnr)
  end
  if require("organ.buf_config").read(bufnr, "modern.pill_caps") == false then
    left, right = "", ""
  end
  badge.emit(NS, bufnr, row, e.col, e.end_col, {
    body_hl = e.hl_group,
    cap_hl = e.cap_hl,
    left_cap = left,
    right_cap = right,
    ephemeral = ephemeral,
  })
end

local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  ensure_pill_highlights()
  -- Tree is parsed once per buffer per redraw by organ.decoration; we
  -- just query the cached tree here.  We also need the parser handle
  -- below to walk injected org_inline trees via for_each_tree.
  local tree = require("organ.decoration").get_tree(bufnr)
  if not tree then
    return
  end

  local kw_set = todo_keywords_set(bufnr)
  local function push(row, col, end_col, hl)
    if row < topline or row > botline then
      return
    end
    frame_map[row] = frame_map[row] or {}
    frame_map[row][#frame_map[row] + 1] = { col = col, end_col = end_col, hl_group = hl }
  end
  -- A keyword pill: reversed body + inline rounded caps at the keyword
  -- boundaries so the surrounding buffer spaces are preserved.
  local function push_pill(row, sc, ec, kw_lower)
    if row < topline or row > botline then
      return
    end
    frame_map[row] = frame_map[row] or {}
    frame_map[row][#frame_map[row] + 1] = {
      col = sc,
      end_col = ec,
      hl_group = "@organ.modern.badge.pill." .. kw_lower,
      cap_hl = "@organ.modern.badgecap.pill." .. kw_lower,
    }
  end

  -- TODO keywords on headlines + timestamp shapes within the title
  -- text.  The inline grammar isn't injected into headline titles,
  -- so we scan the title node's bytes for `<YYYY-MM-DD ...>` /
  -- `[YYYY-MM-DD ...]`.  The scan is bounded to the title node range,
  -- so code blocks, drawers, etc. can't false-positive.
  do
    local q = get_headline_query()
    if q then
      for id, node in q:iter_captures(tree:root(), bufnr, topline, botline + 1) do
        local cap = q.captures[id]
        local sr, sc, er, ec = node:range()
        if cap == "kw" and sr == er then
          local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
          if ok_text and type(text) == "string" and kw_set[text] then
            push_pill(sr, sc, ec, text:lower())
          end
        elseif cap == "title" and sr == er then
          local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
          if ok_text and type(text) == "string" then
            for s, e in text:gmatch("()<%d%d%d%d%-%d%d%-%d%d[^<>\n]*>()") do
              push(sr, sc + s - 1, sc + e - 1, "@organ.modern.badge.pill.timestamp")
            end
            for s, e in text:gmatch("()%[%d%d%d%d%-%d%d%-%d%d[^%[%]\n]*%]()") do
              push(sr, sc + s - 1, sc + e - 1, "@organ.modern.badge.pill.timestamp")
            end
          end
        end
      end
    end
  end

  -- Timestamps from injected org_inline trees overlapping the visible
  -- range.  org_inline is injected into paragraph / headline_line /
  -- list_item / table_row content, so timestamps in any of those
  -- contexts are covered.  We need the parser handle here (the cache
  -- only memoizes the root tree, not the parser); the parse itself has
  -- already happened in organ.decoration's on_buf this redraw.
  do
    local q = get_timestamp_query()
    local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
    if q and ok_parser and parser then
      parser:for_each_tree(function(itree, ltree)
        if ltree:lang() ~= "org_inline" then
          return
        end
        local rsr, _, rer, _ = itree:root():range()
        if rer < topline or rsr > botline then
          return
        end
        for _, node in q:iter_captures(itree:root(), bufnr, topline, botline + 1) do
          local sr, sc, er, ec = node:range()
          if sr == er then
            push(sr, sc, ec, "@organ.modern.badge.pill.timestamp")
          end
        end
      end)
    end
  end
end

local function on_line(bufnr, _winid, row)
  local entries = frame_map[row]
  if not entries then
    return
  end
  for _, e in ipairs(entries) do
    emit(bufnr, row, e, true)
  end
end

require("organ.decoration").register({
  name = "modern_pills",
  ns = NS,
  enabled = function(bufnr)
    return require("organ.buf_config").read(bufnr, "modern.pills") and true or false
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
      emit(bufnr, row, e, false)
    end
  end
end

M._frame_map = function()
  return frame_map
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  register_pill_highlights()
  pcall(function()
    require("organ.decoration").attach(bufnr)
  end)
  M._apply(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.pills")
  return on and true or false
end

-- Reapply hook: react to live `modern.pills` flips on this buffer.
require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local want = require("organ.buf_config").read(bufnr, "modern.pills") and true or false
  if want then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
