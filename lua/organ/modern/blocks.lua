-- Block-frame decoration (org-modern's `org-modern-block-name`).
--
-- Replaces literal `#+begin_TYPE [...]` and `#+end_TYPE` lines with
-- box-drawing decoration:
--
--   #+begin_src lua             →    ┌── lua ──
--     <body>                          <body>
--   #+end_src                   →    └──
--
-- Done with extmark virt_text overlay (the underlying line text is
-- preserved; only the rendered representation changes). Works for any
-- of: src_block, example_block, quote_block, verse_block, export_block,
-- comment_block, special_block, greater_block.
--
-- Runs as an `organ.decoration` provider: `on_lines` rebuilds a per-
-- buffer two-layer cache by walking the tree-sitter `*_block` nodes.
-- The block_ranges layer maps each begin-row to its end-row + label +
-- inner width; the derived per-row layer maps every row inside any
-- block to `{ kind = "top"|"body"|"bot", block_start = N }` so on_line
-- can emit the right extmark in O(1).  Tree-sitter's incremental
-- parse keeps the rebuild cost bounded; a 150ms debounce smooths
-- per-keystroke edits because the build forces `parser:parse(true)`.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_blocks")
M._ns = NS

-- Per-window saved conceallevel -- frames need conceal=2 to hide the
-- raw `#+begin_…` text.
M._saved_conceallevel = M._saved_conceallevel or {}

-- Box drawing primitives.  `TL`/`TR`/`BL`/`BR` are the four corners;
-- `H` is the horizontal rule char; `V` is the vertical bar.  `LBL_LEAD`
-- and `LBL_TAIL` decorate the label on the top line; `LSIDE` is the
-- left side bar plus 1 col of inner padding.
local TL = "┌"
local TR = "┐"
local BL = "└"
local BR = "┘"
local H = "─"
local V = "│"
local LBL_LEAD = "── "
local LBL_TAIL = " "
local LSIDE = V .. " "

local LBL_LEAD_W = vim.fn.strdisplaywidth(LBL_LEAD)
local LBL_TAIL_W = vim.fn.strdisplaywidth(LBL_TAIL)
-- Minimum dashes after the label on top so a label-only block still
-- has visible rule beyond the label, e.g. `┌── x ───┐` not `┌── x ┐`.
local MIN_TRAILING_DASHES = 3

local BEGIN_PAT = "^(%s*)#%+[bB][eE][gG][iI][nN]_([%w]+)(.*)$"
local END_PAT = "^(%s*)#%+[eE][nN][dD]_([%w]+)%s*$"

-- Tree-sitter `*_block` node types we treat as frames.  greater_block
-- subsumes `#+begin_quote`, `#+begin_<arbitrary>`, etc.; the kind/label
-- comes from the begin-line text in all cases.
local BLOCK_NODES = {
  src_block = true,
  example_block = true,
  verse_block = true,
  export_block = true,
  comment_block = true,
  greater_block = true,
}

local function compute_label(kind, suffix)
  -- For src_block: `#+begin_src lua` -> first token "lua" is the
  -- language, render that as the label.  Other blocks: `#+begin_quote`
  -- -> just the kind.  Suffix-with-content but not first-token-able
  -- (`#+begin_src ` with trailing whitespace only) falls back to kind.
  if suffix and suffix ~= "" then
    local first = suffix:match("^%s*(%S+)")
    if first then
      return first
    end
  end
  return kind
end

-- Inner cols of the box (display width between the left/right
-- corners).  Computed per block:
--   label_min  : LBL_LEAD + label + LBL_TAIL + at least MIN_TRAILING_DASHES
--   body_min   : 1 leading inner space + widest body line + 1 trailing pad
--   source_min : enough that the begin / end virt_text overlay covers
--                its entire source line (otherwise source bytes past
--                the overlay's end leak through, e.g. `hon` from
--                `#+begin_src python` trailing a tight `┌── python ───┐`)
local function inner_width(label_width, body_max_width, source_max_width)
  local label_min = LBL_LEAD_W + label_width + LBL_TAIL_W + MIN_TRAILING_DASHES
  local body_min = 2 + body_max_width
  local source_min = source_max_width - 2 -- minus the two corners
  local m = label_min
  if body_min > m then
    m = body_min
  end
  if source_min > m then
    m = source_min
  end
  return m
end

local function decorate_top(bufnr, lnum0, leading, label, inner, ephemeral)
  local rule_len = inner - LBL_LEAD_W - vim.fn.strdisplaywidth(label) - LBL_TAIL_W
  local trailing = LBL_TAIL .. string.rep(H, rule_len) .. TR
  local virt_text = {
    { leading .. TL .. LBL_LEAD, "@organ.modern.block_frame" },
    { label, "@organ.modern.block_label" },
    { trailing, "@organ.modern.block_frame" },
  }
  local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum0, lnum0 + 1, false)[1] or ""
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum0, 0, {
    end_col = #line_text,
    conceal = "",
    virt_text = virt_text,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    ephemeral = ephemeral or nil,
  })
end

local function decorate_bottom(bufnr, lnum0, leading, inner, ephemeral)
  local rule = string.rep(H, inner)
  local virt_text = {
    { leading .. BL .. rule .. BR, "@organ.modern.block_frame" },
  }
  local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum0, lnum0 + 1, false)[1] or ""
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum0, 0, {
    end_col = #line_text,
    conceal = "",
    virt_text = virt_text,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    ephemeral = ephemeral or nil,
  })
end

-- Decorate a body line with `│ ` at the left and ` <pad>│` at the
-- right so the body sits flush inside the top/bottom corners.  Source
-- line text is left intact; inline virt_text at col 0 pushes the
-- existing content 2 cols right, and a second inline mark at the line's
-- end byte adds the trailing padding + right bar.  `inner` is computed
-- once per block to fit the widest body line (and the label header),
-- so pad is always >= 1.
local function decorate_body(bufnr, lnum0, source, inner, ephemeral)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum0, 0, {
    virt_text = { { LSIDE, "@organ.modern.block_frame" } },
    virt_text_pos = "inline",
    ephemeral = ephemeral or nil,
  })
  local pad = inner - 1 - vim.fn.strdisplaywidth(source)
  if pad < 0 then
    pad = 0
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum0, #source, {
    virt_text = { { string.rep(" ", pad) .. V, "@organ.modern.block_frame" } },
    virt_text_pos = "inline",
    ephemeral = ephemeral or nil,
  })
end

-- block_ranges_by_buf[bufnr][begin_row] = {
--   end_row, lead, end_lead, label, label_width, inner,
-- }
local block_ranges_by_buf = {}

-- cache_by_buf[bufnr][row] = { kind = "top"|"body"|"bot", block_start = N }
local cache_by_buf = {}

local rebuild_timers = {}
M._timers = rebuild_timers
local REBUILD_DEBOUNCE_MS = 150

-- Walk tree-sitter `*_block` nodes and pair their begin/end rows.  For
-- each block, parse the begin/end source lines to recover lead
-- whitespace + label.  Returns a flat list of pair tables ready for
-- the per-block sizing pass.
local function collect_block_pairs(bufnr)
  local pairs_ = {}
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return pairs_
  end
  -- Force a fresh parse so the block tree reflects the latest edit.
  -- The 150ms rebuild debounce bounds per-keystroke cost.
  parser:parse(true)
  local tree = (parser:parse() or {})[1]
  if not tree then
    return pairs_
  end
  local n_lines = vim.api.nvim_buf_line_count(bufnr)

  local function visit(node)
    if BLOCK_NODES[node:type()] then
      local sr, _sc, er, ec = node:range()
      -- end_col == 0 means the node ends at the START of er, so the
      -- last actual row is er - 1.  end_col > 0 means er itself is
      -- the last row (the `#+end_*` line).
      local end_row = ec > 0 and er or er - 1
      if end_row > sr and end_row < n_lines then
        local begin_line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ""
        local end_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
        local lead, kind, suffix = begin_line:match(BEGIN_PAT)
        local end_lead, end_kind = end_line:match(END_PAT)
        if lead and end_lead and kind:lower() == end_kind:lower() then
          local label = compute_label(kind, suffix)
          pairs_[#pairs_ + 1] = {
            begin_lnum = sr,
            end_lnum = end_row,
            lead = lead,
            end_lead = end_lead,
            label = label,
            label_width = vim.fn.strdisplaywidth(label),
          }
        end
      end
    end
    for child in node:iter_children() do
      visit(child)
    end
  end

  visit(tree:root())
  return pairs_
end

-- Build BOTH cache layers from scratch.  Returns (block_ranges, cache).
local function build_cache(bufnr)
  local block_ranges = {}
  local cache = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return block_ranges, cache
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return block_ranges, cache
  end

  local pairs_ = collect_block_pairs(bufnr)
  if #pairs_ == 0 then
    return block_ranges, cache
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Frame lines (begin / end of every paired block) are NOT body lines
  -- in the parent block -- a nested block's frame replaces its row's
  -- decoration in the parent.
  local frame_lines = {}
  for _, p in ipairs(pairs_) do
    frame_lines[p.begin_lnum] = true
    frame_lines[p.end_lnum] = true
  end

  for _, p in ipairs(pairs_) do
    local body_max = 0
    for body = p.begin_lnum + 1, p.end_lnum - 1 do
      if not frame_lines[body] then
        local w = vim.fn.strdisplaywidth(lines[body + 1] or "")
        if w > body_max then
          body_max = w
        end
      end
    end
    -- Width the begin / end overlays must cover so source bytes don't
    -- leak past the rendered virt_text.
    local begin_src_w = vim.fn.strdisplaywidth(lines[p.begin_lnum + 1] or "")
    local end_src_w = vim.fn.strdisplaywidth(lines[p.end_lnum + 1] or "")
    local source_max = begin_src_w > end_src_w and begin_src_w or end_src_w
    local inner = inner_width(p.label_width, body_max, source_max)
    p.inner = inner

    block_ranges[p.begin_lnum] = {
      end_row = p.end_lnum,
      lead = p.lead,
      end_lead = p.end_lead,
      label = p.label,
      label_width = p.label_width,
      inner = inner,
    }

    cache[p.begin_lnum] = { kind = "top", block_start = p.begin_lnum }
    cache[p.end_lnum] = { kind = "bot", block_start = p.begin_lnum }
    for body = p.begin_lnum + 1, p.end_lnum - 1 do
      if not frame_lines[body] then
        cache[body] = {
          kind = "body",
          block_start = p.begin_lnum,
          source = lines[body + 1] or "",
        }
      end
    end
  end

  return block_ranges, cache
end

local function place_row(bufnr, row, entry, block_ranges, ephemeral)
  local range = block_ranges[entry.block_start]
  if not range then
    return
  end
  if entry.kind == "top" then
    decorate_top(bufnr, row, range.lead, range.label, range.inner, ephemeral)
  elseif entry.kind == "bot" then
    decorate_bottom(bufnr, row, range.end_lead, range.inner, ephemeral)
  elseif entry.kind == "body" then
    decorate_body(bufnr, row, entry.source or "", range.inner, ephemeral)
  end
end

local function cancel_rebuild_timer(bufnr)
  local t = rebuild_timers[bufnr]
  if not t then
    return
  end
  rebuild_timers[bufnr] = nil
  pcall(t.stop, t)
  pcall(t.close, t)
end

local function rebuild_now(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ranges, cache = build_cache(bufnr)
  block_ranges_by_buf[bufnr] = ranges
  cache_by_buf[bufnr] = cache
end

local function schedule_rebuild(bufnr)
  cancel_rebuild_timer(bufnr)
  local t = vim.uv.new_timer()
  if not t then
    -- Timer allocation failed (unlikely); fall back to a synchronous
    -- rebuild rather than silently dropping the update.
    rebuild_now(bufnr)
    return
  end
  rebuild_timers[bufnr] = t
  t:start(
    REBUILD_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      rebuild_timers[bufnr] = nil
      pcall(t.stop, t)
      pcall(t.close, t)
      rebuild_now(bufnr)
    end)
  )
end

local function register_highlights()
  vim.api.nvim_set_hl(0, "@organ.modern.block_frame", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "@organ.modern.block_label", { link = "Type", default = true })
end

require("organ.decoration").register({
  name = "modern_blocks",
  ns = NS,
  enabled = function(_bufnr)
    local cfg = require("organ").config
    return (cfg.modern or {}).blocks and true or false
  end,
  on_lines = function(bufnr, _first, _last_old, _last_new)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    -- Full rebuild: tree-sitter's incremental parse keeps the cost
    -- bounded.  Initial population (cache empty) runs synchronously so
    -- the first frame after buffer open has correct decoration;
    -- subsequent edits debounce because the build forces
    -- `parser:parse(true)`.
    if cache_by_buf[bufnr] == nil then
      rebuild_now(bufnr)
      return
    end
    schedule_rebuild(bufnr)
  end,
  on_line = function(bufnr, _winid, row)
    local cache = cache_by_buf[bufnr]
    if not cache then
      return
    end
    local entry = cache[row]
    if not entry then
      return
    end
    local ranges = block_ranges_by_buf[bufnr]
    if not ranges then
      return
    end
    place_row(bufnr, row, entry, ranges, true)
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
  local ranges, cache = build_cache(bufnr)
  block_ranges_by_buf[bufnr] = ranges
  cache_by_buf[bufnr] = cache
  for row, entry in pairs(cache) do
    place_row(bufnr, row, entry, ranges, false)
  end
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  register_highlights()
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
  cancel_rebuild_timer(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  block_ranges_by_buf[bufnr] = nil
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
