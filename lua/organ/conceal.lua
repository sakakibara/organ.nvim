-- Inline emphasis-marker + link-bracket concealment.
--
-- Walks the `org_inline` tree per buffer change and places conceal
-- extmarks that hide the surrounding `*` `/` `_` `+` `=` `~` of bold,
-- italic, underline, strikethrough, verbatim and code spans, plus the
-- `[[target][` prefix and trailing `]]` of `[[target][description]]`
-- links.  Marks have no visual effect at `conceallevel = 0` (Neovim
-- default); the user opts in by setting `conceallevel = 2` on the
-- window or via `:Org conceal toggle`.
--
-- Concealment runs as an `organ.decoration` provider: `on_lines`
-- rewrites a per-buffer span cache for the changed range, and `on_line`
-- emits ephemeral conceal extmarks for the visible row.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_emphasis_conceal")

-- Tree-sitter node-type -> config-key.  Missing or `false` config keeps
-- the markup visible.
local EMPHASIS_TYPES = {
  bold = "bold",
  italic = "italic",
  underline = "underline",
  strike = "strike",
  verbatim = "verbatim",
  code = "code",
}

-- `link_regular` covers `[[target][description]]` and `[[target]]`.
-- When a description is present, hide the leading `[[target][` and the
-- trailing `]]` so only the description renders.  Bare `[[target]]`
-- stays visible (target IS the body).
local LINK_TYPES = {
  link_regular = "links",
}

-- Public list of element keys, ordered for `:Org conceal toggle <Tab>`.
M.ELEMENTS = { "bold", "italic", "underline", "strike", "verbatim", "code", "links" }

local function element_enabled(name)
  local cfg = (require("organ").config.emphasis or {})
  local v = cfg[name]
  if v == nil then
    return true
  end
  return v ~= false
end

-- Per-buffer row span cache: cache_by_buf[bufnr][row] = { span, ... }.
-- Each span: { start_col, end_col, conceal_char }.
local cache_by_buf = {}

-- Per-buffer trailing-debounce timers for the on_lines rebuild path.
-- nvim_buf_attach's on_lines fires synchronously on every keystroke;
-- build_cache does a full inline-tree reparse which costs ~12ms on a
-- 5k-line buffer and >100ms on a large one.  Doing that on every key
-- is unusable, so we coalesce edits into one rebuild 150ms after the
-- user stops typing -- the same UX as the pre-migration TextChangedI
-- debounce.  on_line renders from whatever cache exists; the first
-- frame inside a burst can show stale conceal until the timer fires.
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

-- Build a per-row span list from the inline tree.  Single tree walk;
-- spans are bucketed by row.  Spans whose open/close sit on different
-- rows (multi-line emphasis) produce one entry per affected row.
local function build_cache(bufnr)
  local rows = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return rows
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return rows
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return rows
  end
  pcall(function()
    parser:parse(true)
  end)

  local function push(row, start_col, end_col)
    if end_col <= start_col then
      return
    end
    rows[row] = rows[row] or {}
    rows[row][#rows[row] + 1] = { start_col = start_col, end_col = end_col }
  end

  local function walk_emphasis(node)
    local sr, sc, er, ec = node:range()
    -- Open marker: one byte at (sr, sc).
    push(sr, sc, sc + 1)
    -- Close marker: one byte at (er, ec-1), but only if open != close.
    if er > sr or ec > sc + 1 then
      push(er, math.max(0, ec - 1), ec)
    end
  end

  local function walk_link(node)
    local desc_node, target_node
    for c in node:iter_children() do
      local t = c:type()
      if t == "link_description" then
        desc_node = c
      elseif t == "link_target" then
        target_node = c
      end
    end
    if not desc_node then
      return -- bare `[[target]]` -- show as-is
    end
    local sr, sc, er, ec = node:range()
    if target_node then
      local _, _, ter, tec = target_node:range()
      -- target_end .. target_end+2 covers `][` (single-line links).
      if ter == sr then
        push(sr, sc, tec + 2)
      end
    else
      -- Parser quirk: no target node.  Fall back to leading `[[`.
      push(sr, sc, sc + 2)
    end
    -- Trailing `]]`.
    if er == sr then
      push(er, ec - 2, ec)
    end
  end

  -- parser:children() returns a string-keyed table (lang -> child); ipairs
  -- skips it, so iterate via pairs.
  for _, child in pairs(parser:children()) do
    if child:lang() == "org_inline" then
      for _, tree in ipairs(child:trees() or {}) do
        local root = tree:root()
        local function walk(node)
          local t = node:type()
          local emph = EMPHASIS_TYPES[t]
          if emph and element_enabled(emph) then
            walk_emphasis(node)
          elseif LINK_TYPES[t] and element_enabled(LINK_TYPES[t]) then
            walk_link(node)
          end
          for c in node:iter_children() do
            walk(c)
          end
        end
        walk(root)
      end
    end
  end

  return rows
end

-- Place all cached spans for `bufnr` as non-ephemeral extmarks.  Used
-- by `_apply` (test-facing) and by `toggle_element` for an immediate
-- visible refresh independent of frame dispatch.
local function place_marks(bufnr, rows)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  for row, spans in pairs(rows) do
    for _, s in ipairs(spans) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, s.start_col, {
        end_col = s.end_col,
        conceal = "",
      })
    end
  end
end

local function schedule_rebuild(bufnr)
  cancel_rebuild_timer(bufnr)
  local t = vim.uv.new_timer()
  if not t then
    -- Timer allocation failed (unlikely); fall back to a synchronous
    -- rebuild rather than silently dropping the update.
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
  name = "conceal",
  ns = NS,
  enabled = function(_bufnr)
    -- Walker is always on; per-element gating happens in `build_cache`
    -- via `element_enabled()`.  The conceallevel check in `on_line`
    -- skips actual extmark placement when the window won't render
    -- conceal anyway.
    return true
  end,
  on_lines = function(bufnr, _first, _last_old, _last_new)
    -- Inline emphasis can span unbounded text; an edit that closes or
    -- opens a marker shifts every span on subsequent rows.  Rebuilding
    -- the whole cache is the only correct option.  Initial population
    -- (cache empty) runs synchronously so the first frame after buffer
    -- open has correct decoration; subsequent edits debounce.
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
    local spans = rows[row]
    if not spans or #spans == 0 then
      return
    end
    for _, s in ipairs(spans) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, s.start_col, {
        end_col = s.end_col,
        conceal = "",
        ephemeral = true,
      })
    end
  end,
})

-- Test-facing: rebuild the cache + place non-ephemeral extmarks now.
-- Useful when callers need to assert via `nvim_buf_get_extmarks` without
-- waiting for a frame, and as a fallback path for buffers that aren't
-- attached to `organ.decoration` (no FileType=org autocmd fired yet).
local function apply(bufnr)
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

M._apply = apply

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  cache_by_buf[bufnr] = nil
  cancel_rebuild_timer(bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { limit = 1 })
  if #marks > 0 then
    M.detach(bufnr)
    vim.wo.conceallevel = 0
    return false
  end
  apply(bufnr)
  if vim.wo.conceallevel == 0 then
    vim.wo.conceallevel = 2
  end
  return true
end

-- Flip a single element's config flag and re-apply.  Returns the new
-- state (true = concealed, false = visible).  Per-element flags live
-- on the in-process config so toggles persist for the rest of the
-- session; users wanting persistent preferences set them in `setup()`.
function M.toggle_element(name)
  local cfg = require("organ").config
  cfg.emphasis = cfg.emphasis or {}
  local cur = cfg.emphasis[name]
  if cur == nil then
    cur = true
  end
  cfg.emphasis[name] = not cur
  -- Re-walk every loaded org buffer so the change is reflected
  -- immediately, not on the next TextChanged.  `apply` rebuilds the
  -- cache AND places non-ephemeral extmarks for the current rendered
  -- frame; the decoration provider's on_line path will pick the new
  -- cache up on subsequent redraws.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      apply(b)
    end
  end
  return cfg.emphasis[name]
end

M.commands = {
  ["conceal toggle"] = {
    fn = function(opts)
      local arg = opts and opts.args or ""
      if arg == nil or arg == "" then
        local on = M.toggle(0)
        require("organ.notify").info("organ: emphasis conceal " .. (on and "ON" or "OFF"))
        return
      end
      if not vim.tbl_contains(M.ELEMENTS, arg) then
        require("organ.notify").warn(
          "organ: unknown element `" .. arg .. "`; valid: " .. table.concat(M.ELEMENTS, " ")
        )
        return
      end
      local on = M.toggle_element(arg)
      require("organ.notify").info("organ: conceal " .. arg .. " = " .. (on and "ON" or "OFF"))
    end,
    nargs = "?",
    complete = function()
      return M.ELEMENTS
    end,
    desc = "Toggle conceal: master (no arg) or one element (bold / italic / ... / links)",
  },
}

return M
