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

local function register_pill_highlights()
  -- Inverse-video versions of the per-keyword TODO groups. We can't
  -- just override @org.todo.* directly -- that would also affect plain
  -- text highlights elsewhere. So we register sibling pill groups and
  -- attach them via extmarks.
  --
  -- The pill background comes from the existing fg color of the
  -- TODO group via reverse=true (vim swaps fg <-> bg for the cell).
  for _, kw in ipairs({
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
  }) do
    vim.api.nvim_set_hl(
      0,
      "@organ.modern.pill." .. kw,
      { link = "@org.todo." .. kw, default = true, reverse = true, bold = true }
    )
  end
  vim.api.nvim_set_hl(
    0,
    "@organ.modern.pill.timestamp",
    { link = "@org.timestamp", default = true, reverse = true }
  )
end

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
local function todo_keywords_set()
  local seq = (require("organ").config.todo or {}).sequence or {}
  local set = {}
  for _, k in ipairs(seq) do
    if k ~= "|" then
      set[k] = true
    end
  end
  return set
end

-- Frame-local row map: frame_map[row] = { { col, end_col, hl_group }, ... }.
-- Reset at the start of every on_win call; read by on_line for the
-- same frame.  No per-buffer keying: only one window's on_win runs
-- before its on_line callbacks for the same frame.
local frame_map = {}

local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok_parser or not parser then
    return
  end
  -- Range-bounded incremental parse.  Tree-sitter's edit tracking
  -- keeps the rest of the tree correct; we never call parser:parse(true).
  parser:parse({ topline, 0, botline + 1, 0 })

  local kw_set = todo_keywords_set()
  local function push(row, col, end_col, hl)
    if row < topline or row > botline then
      return
    end
    frame_map[row] = frame_map[row] or {}
    frame_map[row][#frame_map[row] + 1] = { col = col, end_col = end_col, hl_group = hl }
  end

  -- TODO keywords on headlines + timestamp shapes within the title
  -- text.  The inline grammar isn't injected into headline titles,
  -- so we scan the title node's bytes for `<YYYY-MM-DD ...>` /
  -- `[YYYY-MM-DD ...]`.  The scan is bounded to the title node range,
  -- so code blocks, drawers, etc. can't false-positive.
  do
    local tree = (parser:trees() or {})[1]
    local q = get_headline_query()
    if tree and q then
      for id, node in q:iter_captures(tree:root(), bufnr, topline, botline + 1) do
        local cap = q.captures[id]
        local sr, sc, er, ec = node:range()
        if cap == "kw" and sr == er then
          local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
          if ok_text and type(text) == "string" and kw_set[text] then
            push(sr, sc, ec, "@organ.modern.pill." .. text:lower())
          end
        elseif cap == "title" and sr == er then
          local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
          if ok_text and type(text) == "string" then
            for s, e in text:gmatch("()<%d%d%d%d%-%d%d%-%d%d[^<>\n]*>()") do
              push(sr, sc + s - 1, sc + e - 1, "@organ.modern.pill.timestamp")
            end
            for s, e in text:gmatch("()%[%d%d%d%d%-%d%d%-%d%d[^%[%]\n]*%]()") do
              push(sr, sc + s - 1, sc + e - 1, "@organ.modern.pill.timestamp")
            end
          end
        end
      end
    end
  end

  -- Timestamps from injected org_inline trees overlapping the visible
  -- range.  org_inline is injected into paragraph / headline_line /
  -- list_item / table_row content, so timestamps in any of those
  -- contexts are covered.
  do
    local q = get_timestamp_query()
    if q then
      parser:for_each_tree(function(tree, ltree)
        if ltree:lang() ~= "org_inline" then
          return
        end
        local rsr, _, rer, _ = tree:root():range()
        if rer < topline or rsr > botline then
          return
        end
        for _, node in q:iter_captures(tree:root(), bufnr, topline, botline + 1) do
          local sr, sc, er, ec = node:range()
          if sr == er then
            push(sr, sc, ec, "@organ.modern.pill.timestamp")
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
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, e.col, {
      end_col = e.end_col,
      hl_group = e.hl_group,
      priority = 200, -- above the base TS highlight
      ephemeral = true,
    })
  end
end

require("organ.decoration").register({
  name = "modern_pills",
  ns = NS,
  enabled = function(_bufnr)
    local cfg = require("organ").config
    return (cfg.modern or {}).pills and true or false
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
        hl_group = e.hl_group,
        priority = 200,
      })
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
  local cfg = require("organ").config.modern or {}
  if cfg.pills then
    cfg.pills = false
    M.detach(bufnr)
    return false
  end
  cfg.pills = true
  M.attach(bufnr)
  return true
end

return M
