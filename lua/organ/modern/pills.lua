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

-- Rounded pill caps: Nerd Font half-circle glyphs colored like the body,
-- overlaid on the spaces flanking the keyword so the badge reads as a pill
-- rather than a box.  Built from codepoints to keep the source ASCII.
local DEFAULT_CAP_LEFT = vim.fn.nr2char(0xe0b6) -- left half circle
local DEFAULT_CAP_RIGHT = vim.fn.nr2char(0xe0b4) -- right half circle

-- Resolve the configured caps.  `modern.pill_caps = false` -> box mode (no
-- caps); a table overrides the glyphs.  Returns (left, right) or nil, nil.
local function pill_caps(bufnr)
  local cfg = require("organ.buf_config").read(bufnr, "modern.pill_caps")
  if cfg == false then
    return nil, nil
  end
  if type(cfg) == "table" then
    return cfg.left or DEFAULT_CAP_LEFT, cfg.right or DEFAULT_CAP_RIGHT
  end
  return DEFAULT_CAP_LEFT, DEFAULT_CAP_RIGHT
end

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

-- Standalone reversed body group + a solid cap group per keyword, both
-- derived from the keyword's resolved @org.todo.<kw> color (set by
-- organ.highlights from its semantic bucket).  These CANNOT link to
-- @org.todo.<kw>: nvim_set_hl drops gui attributes (reverse) when `link`
-- is present, which is why pills used to render as plain text.  So we copy
-- the resolved fg into a fresh group with reverse applied.
local function register_pill_highlights()
  local H = require("organ.highlights")
  local function pill(name, color, reverse)
    if color then
      local attrs = { fg = color, bold = true }
      if reverse then
        attrs.reverse = true
      end
      vim.api.nvim_set_hl(0, name, attrs)
    end
  end
  for _, kw in ipairs(PILL_KEYWORDS) do
    local color = H.resolved_fg("@org.todo." .. kw)
    pill("@organ.modern.pill." .. kw, color, true) -- reversed body
    pill("@organ.modern.pillcap." .. kw, color, false) -- solid cap
  end
  local ts = H.resolved_fg("@org.timestamp") or H.resolved_fg("@org.timestamp.active")
  pill("@organ.modern.pill.timestamp", ts, true)
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
-- { col, end_col, hl_group } for a timestamp box; a rounded keyword pill
-- also carries cap_hl + left_col + (right_col | right_eol).  Reset each
-- on_win; read by on_line for the same frame.  frame_cap_* hold the
-- resolved cap glyphs for the frame (nil in box mode).
local frame_map = {}
local frame_cap_left, frame_cap_right

-- Place one frame entry's extmarks: the reversed body plus, for keyword
-- pills, the rounded caps overlaid on the flanking spaces.
local function emit(bufnr, row, e, ephemeral)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, e.col, {
    end_col = e.end_col,
    hl_group = e.hl_group,
    priority = 200, -- above the base TS highlight
    ephemeral = ephemeral or nil,
  })
  if not e.cap_hl or not frame_cap_left then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, e.left_col, {
    virt_text = { { frame_cap_left, e.cap_hl } },
    virt_text_pos = "overlay",
    priority = 200,
    ephemeral = ephemeral or nil,
  })
  if e.right_col then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, e.right_col, {
      virt_text = { { frame_cap_right, e.cap_hl } },
      virt_text_pos = "overlay",
      priority = 200,
      ephemeral = ephemeral or nil,
    })
  elseif e.right_eol then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, e.end_col, {
      virt_text = { { frame_cap_right, e.cap_hl } },
      priority = 200,
      ephemeral = ephemeral or nil,
    })
  end
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
  frame_cap_left, frame_cap_right = pill_caps(bufnr)
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
  -- A keyword pill: reversed body + rounded caps.  The left cap overlays the
  -- space between the stars and the keyword; the right cap overlays the space
  -- before the title, or sits at line end when the keyword has no title.
  local function push_pill(row, sc, ec, kw_lower)
    if row < topline or row > botline then
      return
    end
    local ln = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local entry = {
      col = sc,
      end_col = ec,
      hl_group = "@organ.modern.pill." .. kw_lower,
      cap_hl = "@organ.modern.pillcap." .. kw_lower,
      left_col = sc - 1,
    }
    if ln:sub(ec + 1, ec + 1) == " " then
      entry.right_col = ec
    else
      entry.right_eol = true
    end
    frame_map[row] = frame_map[row] or {}
    frame_map[row][#frame_map[row] + 1] = entry
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
