-- Block-frame decoration (org-modern's `org-modern-block-name`).
--
-- Replaces literal `#+begin_TYPE [...]` and `#+end_TYPE` lines with
-- box-drawing decoration:
--
--   #+begin_src lua             ->    ┌── lua ──
--     <body>                          <body>
--   #+end_src                   ->    └──
--
-- Done with extmark virt_text overlay (the underlying line text is
-- preserved; only the rendered representation changes). Works for any
-- of: src_block, example_block, quote_block, verse_block, export_block,
-- comment_block, special_block, greater_block.
--
-- Runs as an `organ.decoration` provider: `on_win` queries `*_block`
-- nodes intersecting `[topline, botline+1)` via a range-bounded
-- tree-sitter query (O(visible_blocks)), computes each block's
-- inner_width from its widest body line (which may extend past the
-- visible range), and populates a module-local frame-row map for rows
-- in `[topline, botline]`.  `on_line` reads from that map and emits
-- ephemeral overlay / inline virt_text marks for the current row.  The
-- tree is parsed once per buffer per redraw by organ.decoration and
-- shared with the other decoration providers.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_blocks")
M._ns = NS

-- Per-window saved conceallevel -- frames need conceal=2 to hide the
-- raw `#+begin_...` text.
M._saved_conceallevel = M._saved_conceallevel or {}

-- Empty-table sentinel.  Memory-probe tests may inspect this; the
-- on_win design has no timers, but the assertion stays meaningful
-- because the table stays empty.
M._timers = {}

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

-- Range-bounded block query.  greater_block subsumes `#+begin_quote`,
-- `#+begin_<arbitrary>`, etc.; the kind/label comes from the begin-line
-- text in all cases.  `iter_captures` with (topline, botline+1) is
-- range-bounded at the C-level tree-sitter library and skips subtrees
-- that don't intersect, so per-frame work is O(visible_blocks) rather
-- than O(all_blocks).  Parsed lazily and cached at module scope.
local _block_query
local function get_block_query()
  if _block_query then
    return _block_query
  end
  local ok, parsed = pcall(
    vim.treesitter.query.parse,
    "org",
    [[
    (src_block) @b
    (example_block) @b
    (verse_block) @b
    (export_block) @b
    (comment_block) @b
    (greater_block) @b
  ]]
  )
  if ok then
    _block_query = parsed
  end
  return _block_query
end

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

-- Frame-local row map: frame_map[row] = {
--   kind = "top"|"body"|"bot",
--   range = { end_row, lead, end_lead, label, inner },
--   source = <line text> (body only),
-- }.  Reset at the start of every on_win call; read by on_line for the
-- same frame.  Only rows in [topline, botline] are populated, but
-- inner widths reflect the WHOLE block (body lines outside the visible
-- range still factor into width).
local frame_map = {}

local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.blocks") then
    return
  end
  -- Tree is parsed once per buffer per redraw by organ.decoration; we
  -- just query the cached tree here.
  local tree = require("organ.decoration").get_tree(bufnr)
  if not tree then
    return
  end

  local q = get_block_query()
  if not q then
    return
  end

  local n_lines = vim.api.nvim_buf_line_count(bufnr)
  local pairs_ = {}

  -- Range-bounded query: only blocks whose extent intersects
  -- [topline, botline+1) are yielded.  Subtrees that don't overlap are
  -- skipped at the C level, so cost is O(visible_blocks).
  for _, node in q:iter_captures(tree:root(), bufnr, topline, botline + 1) do
    local sr, _, er, ec = node:range()
    -- end_col == 0 means the node ends at the START of er, so the last
    -- actual row is er - 1.  end_col > 0 means er itself is the last
    -- row (the `#+end_*` line).
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

  if #pairs_ == 0 then
    return
  end

  -- Frame lines (begin / end of every paired block) are NOT body lines
  -- in the parent block -- a nested block's frame replaces its row's
  -- decoration in the parent.
  local frame_lines = {}
  for _, p in ipairs(pairs_) do
    frame_lines[p.begin_lnum] = true
    frame_lines[p.end_lnum] = true
  end

  for _, p in ipairs(pairs_) do
    -- inner_width must reflect the WHOLE block (body lines outside the
    -- visible range still factor into width), but we only need this
    -- block's body lines, not the whole buffer.
    local body_max = 0
    if p.end_lnum > p.begin_lnum + 1 then
      local body_lines = vim.api.nvim_buf_get_lines(bufnr, p.begin_lnum + 1, p.end_lnum, false)
      for body_idx, body_line in ipairs(body_lines) do
        local body_row = p.begin_lnum + body_idx
        if not frame_lines[body_row] then
          local w = vim.fn.strdisplaywidth(body_line)
          if w > body_max then
            body_max = w
          end
        end
      end
    end
    -- Width the begin / end overlays must cover so source bytes don't
    -- leak past the rendered virt_text.
    local begin_src_w = vim.fn.strdisplaywidth(
      vim.api.nvim_buf_get_lines(bufnr, p.begin_lnum, p.begin_lnum + 1, false)[1] or ""
    )
    local end_src_w = vim.fn.strdisplaywidth(
      vim.api.nvim_buf_get_lines(bufnr, p.end_lnum, p.end_lnum + 1, false)[1] or ""
    )
    local source_max = begin_src_w > end_src_w and begin_src_w or end_src_w
    local inner = inner_width(p.label_width, body_max, source_max)

    local range_info = {
      end_row = p.end_lnum,
      lead = p.lead,
      end_lead = p.end_lead,
      label = p.label,
      inner = inner,
    }

    -- Populate frame_map only for rows in [topline, botline].  Inner
    -- width above already reflects the whole block.
    if p.begin_lnum >= topline and p.begin_lnum <= botline then
      frame_map[p.begin_lnum] = { kind = "top", range = range_info }
    end
    if p.end_lnum >= topline and p.end_lnum <= botline then
      frame_map[p.end_lnum] = { kind = "bot", range = range_info }
    end
    if p.end_lnum > p.begin_lnum + 1 then
      local body_start = math.max(p.begin_lnum + 1, topline)
      local body_end = math.min(p.end_lnum - 1, botline)
      if body_start <= body_end then
        local body_lines = vim.api.nvim_buf_get_lines(bufnr, body_start, body_end + 1, false)
        for body_idx, body_line in ipairs(body_lines) do
          local body_row = body_start + body_idx - 1
          if not frame_lines[body_row] then
            frame_map[body_row] = {
              kind = "body",
              range = range_info,
              source = body_line,
            }
          end
        end
      end
    end
  end
end

local function on_line(bufnr, _winid, row)
  local entry = frame_map[row]
  if not entry then
    return
  end
  if entry.kind == "top" then
    decorate_top(bufnr, row, entry.range.lead, entry.range.label, entry.range.inner, true)
  elseif entry.kind == "bot" then
    decorate_bottom(bufnr, row, entry.range.end_lead, entry.range.inner, true)
  elseif entry.kind == "body" then
    decorate_body(bufnr, row, entry.source or "", entry.range.inner, true)
  end
end

local function register_highlights()
  vim.api.nvim_set_hl(0, "@organ.modern.block_frame", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "@organ.modern.block_label", { link = "Type", default = true })
end

require("organ.decoration").register({
  name = "modern_blocks",
  ns = NS,
  enabled = function(bufnr)
    return require("organ.buf_config").read(bufnr, "modern.blocks") and true or false
  end,
  on_win = on_win,
  on_line = on_line,
})

M._frame_map = function()
  return frame_map
end

-- Test-facing + ftplugin entrypoint.  Drive on_win full-buffer and
-- place non-ephemeral marks for every populated row so callers
-- asserting via `nvim_buf_get_extmarks` see them without waiting for a
-- real frame.
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  on_win(bufnr, 0, 0, n - 1)
  for row, entry in pairs(frame_map) do
    if entry.kind == "top" then
      decorate_top(bufnr, row, entry.range.lead, entry.range.label, entry.range.inner, false)
    elseif entry.kind == "bot" then
      decorate_bottom(bufnr, row, entry.range.end_lead, entry.range.inner, false)
    elseif entry.kind == "body" then
      decorate_body(bufnr, row, entry.source or "", entry.range.inner, false)
    end
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
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] ~= nil then
    vim.wo.conceallevel = M._saved_conceallevel[winid]
    M._saved_conceallevel[winid] = nil
  end
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.blocks")
  return on and true or false
end

-- Reapply hook: react to live `modern.blocks` flips on this buffer.
require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local want = require("organ.buf_config").read(bufnr, "modern.blocks") and true or false
  if want then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
