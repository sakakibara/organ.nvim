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
-- Runs as an `organ.decoration` provider: `on_lines` rebuilds a per-
-- buffer row cache by walking the tree (TODO keyword on headline_line,
-- timestamp_active / timestamp_inactive / timestamp_range_* nodes from
-- the injected org_inline grammar, plus a bounded `<...>` / `[...]`
-- scan WITHIN headline_line title bytes since the inline grammar isn't
-- injected into titles).  `on_line` emits ephemeral hl extmarks for
-- the visible row.  Tree-sitter is the source of truth: the inline-
-- grammar timestamp nodes correctly exclude code blocks, drawers, and
-- other inert contexts where a `<...>` / `[...]` regex would false-
-- positive; the title-bytes scan is bounded to the title node range,
-- so it inherits the same node-level scoping.

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
-- pill hl group.  Recomputed on each build_cache so config changes
-- take effect without a session restart.
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

-- Per-buffer row cache: cache_by_buf[bufnr][row] = { entry, ... } where
-- each entry is { col = N, end_col = N, hl_group = "<group>" }.  Multiple
-- entries per row are expected (a headline can carry both a TODO keyword
-- and a timestamp).  Rows with no pills are absent.
local cache_by_buf = {}

-- Build the per-row cache by walking the org tree (TODO keyword on
-- each headline_line) and the org_inline injected tree (timestamp
-- nodes).  Tree-sitter is the source of truth: timestamps inside
-- code blocks / verbatim won't be in the inline tree, so they won't
-- get pilled.
local function build_cache(bufnr)
  local rows = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return rows
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return rows
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok_parser or not parser then
    return rows
  end

  local function push(row, col, end_col, hl)
    rows[row] = rows[row] or {}
    rows[row][#rows[row] + 1] = { col = col, end_col = end_col, hl_group = hl }
  end

  -- Force a fresh parse so injected trees are populated for the
  -- timestamp walk below.
  parser:parse(true)

  -- TODO keywords on headlines + timestamp shapes within the title
  -- text.  The inline grammar isn't injected into headline titles,
  -- so we scan the title node's bytes for `<YYYY-MM-DD ...>` /
  -- `[YYYY-MM-DD ...]`.  The scan is bounded to the title node range,
  -- so code blocks, drawers, etc. can't false-positive.
  local kw_set = todo_keywords_set()
  do
    local tree = (parser:trees() or {})[1]
    local q = get_headline_query()
    if tree and q then
      for id, node in q:iter_captures(tree:root(), bufnr, 0, -1) do
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

  -- Timestamps from the injected org_inline trees.  Iterate every
  -- child tree whose language is org_inline; org_inline is injected
  -- into paragraph / headline_line / list_item / table_row content,
  -- so timestamps in any of those contexts are covered.
  do
    local q = get_timestamp_query()
    if q then
      parser:for_each_tree(function(tree, ltree)
        if ltree:lang() ~= "org_inline" then
          return
        end
        for _, node in q:iter_captures(tree:root(), bufnr, 0, -1) do
          local sr, sc, er, ec = node:range()
          if sr == er then
            push(sr, sc, ec, "@organ.modern.pill.timestamp")
          end
        end
      end)
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
      hl_group = e.hl_group,
      priority = 200, -- above the base TS highlight
      ephemeral = ephemeral or nil,
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
  register_pill_highlights()
  pcall(function()
    require("organ.decoration").attach(bufnr)
  end)
  M._apply(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  cache_by_buf[bufnr] = nil
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
