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

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_blocks")

local function clear(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

local BEGIN_PAT = "^(%s*)#%+[bB][eE][gG][iI][nN]_([%w]+)(.*)$"
local END_PAT = "^(%s*)#%+[eE][nN][dD]_([%w]+)%s*$"

-- Per-window saved conceallevel — frames need conceal=2 to hide the
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
local TRAILING_RULE_LEN = 30 -- horizontal chars after the label on the top line

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

local LBL_LEAD_W = vim.fn.strdisplaywidth(LBL_LEAD)
local LBL_TAIL_W = vim.fn.strdisplaywidth(LBL_TAIL)
-- Minimum dashes after the label on top so a label-only block still
-- has visible rule beyond the label, e.g. `┌── x ───┐` not `┌── x ┐`.
local MIN_TRAILING_DASHES = 3

-- Inner cols of the box (display width between the left/right
-- corners).  Computed per block:
--   label_min  : LBL_LEAD + label + LBL_TAIL + at least MIN_TRAILING_DASHES
--   body_min   : 1 leading inner space + widest body line + 1 trailing pad
--   source_min : enough that the begin / end virt_text overlay covers
--                its entire source line (otherwise source bytes past
--                the overlay's end leak through, e.g. `hon` from
--                `#+begin_src python` trailing a tight `┌── python ───┐`)
-- No fixed cap; the box is sized to its content.
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

local function decorate_top(bufnr, lnum0, leading, label, inner)
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
  })
end

local function decorate_bottom(bufnr, lnum0, leading, inner)
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
  })
end

-- Decorate a body line with `│ ` at the left and ` <pad>│` at the
-- right so the body sits flush inside the top/bottom corners.  Source
-- line text is left intact; inline virt_text at col 0 pushes the
-- existing content 2 cols right, and a second inline mark at the line's
-- end byte adds the trailing padding + right bar.  `inner` is computed
-- once per block to fit the widest body line (and the label header),
-- so pad is always >= 1.
local function decorate_body(bufnr, lnum0, source, inner)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum0, 0, {
    virt_text = { { LSIDE, "@organ.modern.block_frame" } },
    virt_text_pos = "inline",
  })
  local pad = inner - 1 - vim.fn.strdisplaywidth(source)
  if pad < 0 then
    pad = 0
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum0, #source, {
    virt_text = { { string.rep(" ", pad) .. V, "@organ.modern.block_frame" } },
    virt_text_pos = "inline",
  })
end

local function apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  clear(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- First pass: pair begin / end lines by kind, recording each pair's
  -- range and label width.  Stack-based matching handles nested blocks
  -- (greater_block containing src_block etc.).  No decoration emitted
  -- in this pass -- we need the body-line range first to size the box.
  local pairs_ = {}
  do
    local begins = {}
    for i, line in ipairs(lines) do
      local lead, kind, suffix = line:match(BEGIN_PAT)
      if lead then
        local label = compute_label(kind, suffix)
        table.insert(begins, {
          kind = kind,
          lnum0 = i - 1,
          lead = lead,
          label = label,
          label_width = vim.fn.strdisplaywidth(label),
        })
      else
        lead, kind = line:match(END_PAT)
        if lead then
          for j = #begins, 1, -1 do
            if begins[j].kind == kind then
              local b = begins[j]
              pairs_[#pairs_ + 1] = {
                begin_lnum = b.lnum0,
                end_lnum = i - 1,
                lead = b.lead,
                label = b.label,
                label_width = b.label_width,
                end_lead = lead,
              }
              table.remove(begins, j)
              break
            end
          end
        end
      end
    end
  end
  -- Frame lines (begin / end of every paired block) get their own
  -- decoration; body decoration skips them so a side bar doesn't
  -- stack over the top / bottom overlay.
  local frame_lines = {}
  for _, p in ipairs(pairs_) do
    frame_lines[p.begin_lnum] = true
    frame_lines[p.end_lnum] = true
  end
  -- Second pass: per pair, compute body_max_width across non-frame
  -- body lines and emit top / body / bottom decoration with a unified
  -- inner width.
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
    decorate_top(bufnr, p.begin_lnum, p.lead, p.label, inner)
    decorate_bottom(bufnr, p.end_lnum, p.end_lead, inner)
    for body = p.begin_lnum + 1, p.end_lnum - 1 do
      if not frame_lines[body] then
        decorate_body(bufnr, body, lines[body + 1] or "", inner)
      end
    end
  end
end

local function register_highlights()
  vim.api.nvim_set_hl(0, "@organ.modern.block_frame", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "@organ.modern.block_label", { link = "Type", default = true })
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

  require("organ.debounce").apply_initial(bufnr, apply)
  local group = vim.api.nvim_create_augroup("organ_modern_blocks_" .. bufnr, { clear = true })
  local trigger = require("organ.debounce").trailing(150, function(b)
    if vim.api.nvim_buf_is_valid(b) then
      apply(b)
    end
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      trigger(bufnr)
    end,
  })
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  clear(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "organ_modern_blocks_" .. bufnr)
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

M._apply = apply

return M
