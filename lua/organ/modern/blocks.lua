-- Block-frame decoration (org-modern's `org-modern-block-name`).
--
-- Replaces literal `#+begin_TYPE [...]` and `#+end_TYPE` lines with a rounded
-- box-drawing frame and boxes the body:
--
--   #+begin_src lua             ->    ╭── lua ───────╮
--     <body>                          │ <body>       │
--   #+end_src                   ->    ╰──────────────╯
--
-- Works for src / example / verse / export / comment / greater blocks.
--
-- Rendered through `organ.modern.render` (the persistent engine). The body
-- side bars are INLINE virt_text, which the ephemeral decoration provider
-- silently dropped; non-ephemeral engine marks render them. The engine raises
-- conceallevel so the raw `#+begin_/#+end_` lines hide behind the overlay.

local M = {}

-- Box drawing primitives. Rounded corners `╭ ╮ ╰ ╯`; `H` horizontal rule; `V`
-- vertical bar. `LBL_LEAD`/`LBL_TAIL` decorate the top-line label; `LSIDE` is
-- the left side bar plus one inner pad column.
local TL = "╭"
local TR = "╮"
local BL = "╰"
local BR = "╯"
local H = "─"
local V = "│"
local LBL_LEAD = "── "
local LBL_TAIL = " "
local LSIDE = V .. " "

local LBL_LEAD_W = vim.fn.strdisplaywidth(LBL_LEAD)
local LBL_TAIL_W = vim.fn.strdisplaywidth(LBL_TAIL)
local MIN_TRAILING_DASHES = 3

local BEGIN_PAT = "^(%s*)#%+[bB][eE][gG][iI][nN]_([%w]+)(.*)$"
local END_PAT = "^(%s*)#%+[eE][nN][dD]_([%w]+)%s*$"

local _block_query
local function get_block_query()
  if _block_query then
    return _block_query
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, "org", [[
    (src_block) @b
    (example_block) @b
    (verse_block) @b
    (export_block) @b
    (comment_block) @b
    (greater_block) @b
  ]])
  if ok then
    _block_query = parsed
  end
  return _block_query
end

local function compute_label(kind, suffix)
  if suffix and suffix ~= "" then
    local first = suffix:match("^%s*(%S+)")
    if first then
      return first
    end
  end
  return kind
end

-- Inner columns of the box (display width between the corners). Fits the
-- widest of: the label header, the widest body line, and the raw source line
-- (so source bytes never leak past the overlay).
local function inner_width(label_width, body_max_width, source_max_width)
  local label_min = LBL_LEAD_W + label_width + LBL_TAIL_W + MIN_TRAILING_DASHES
  local body_min = 2 + body_max_width
  local source_min = source_max_width - 2
  local m = label_min
  if body_min > m then
    m = body_min
  end
  if source_min > m then
    m = source_min
  end
  return m
end

local function decorate_top(bufnr, ns, lnum0, leading, label, inner)
  local rule_len = inner - LBL_LEAD_W - vim.fn.strdisplaywidth(label) - LBL_TAIL_W
  local trailing = LBL_TAIL .. string.rep(H, rule_len) .. TR
  local virt_text = {
    { leading .. TL .. LBL_LEAD, "@organ.modern.block_frame" },
    { label, "@organ.modern.block_label" },
    { trailing, "@organ.modern.block_frame" },
  }
  local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum0, lnum0 + 1, false)[1] or ""
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum0, 0, {
    end_col = #line_text,
    conceal = "",
    virt_text = virt_text,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    priority = 200,
  })
end

local function decorate_bottom(bufnr, ns, lnum0, leading, inner)
  local rule = string.rep(H, inner)
  local virt_text = {
    { leading .. BL .. rule .. BR, "@organ.modern.block_frame" },
  }
  local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum0, lnum0 + 1, false)[1] or ""
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum0, 0, {
    end_col = #line_text,
    conceal = "",
    virt_text = virt_text,
    virt_text_pos = "overlay",
    hl_mode = "combine",
    priority = 200,
  })
end

-- `│ ` at the left (inline, pushes body text right) and ` <pad>│` at the line
-- end so the body sits flush inside the corners. `tint` fills the body line
-- with a subtle background.
local function decorate_body(bufnr, ns, lnum0, source, inner, tint)
  if tint then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum0, 0, {
      line_hl_group = "@organ.modern.block_tint",
      priority = 190,
    })
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum0, 0, {
    virt_text = { { LSIDE, "@organ.modern.block_frame" } },
    virt_text_pos = "inline",
    priority = 200,
  })
  local pad = inner - 1 - vim.fn.strdisplaywidth(source)
  if pad < 0 then
    pad = 0
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum0, #source, {
    virt_text = { { string.rep(" ", pad) .. V, "@organ.modern.block_frame" } },
    virt_text_pos = "inline",
    priority = 200,
  })
end

local function register_highlights()
  vim.api.nvim_set_hl(0, "@organ.modern.block_frame", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "@organ.modern.block_label", { link = "Type", default = true })
  vim.api.nvim_set_hl(0, "@organ.modern.block_tint", { link = "CursorLine", default = true })
end

-- Engine renderer: frame every paired block intersecting [top, bot). Inner
-- width reflects the WHOLE block (body lines outside the range still factor
-- in); marks are placed only for rows within [top, bot).
local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.blocks") then
    return
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok_parser or not parser then
    return
  end
  local trees = parser:parse({ top, bot })
  local tree = trees and trees[1]
  if not tree then
    return
  end
  local q = get_block_query()
  if not q then
    return
  end

  local ns = require("organ.modern.render").ns
  local tint = require("organ.buf_config").read(bufnr, "modern.blocks.tint_body") and true or false
  local n_lines = vim.api.nvim_buf_line_count(bufnr)
  local pairs_ = {}

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, _, er, ec = node:range()
    local end_row = ec > 0 and er or er - 1
    if end_row > sr and end_row < n_lines then
      local begin_line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ""
      local end_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""
      local lead, kind, suffix = begin_line:match(BEGIN_PAT)
      local end_lead, end_kind = end_line:match(END_PAT)
      if lead and end_lead and kind:lower() == end_kind:lower() then
        pairs_[#pairs_ + 1] = {
          begin_lnum = sr,
          end_lnum = end_row,
          lead = lead,
          end_lead = end_lead,
          label = compute_label(kind, suffix),
        }
      end
    end
  end
  if #pairs_ == 0 then
    return
  end

  local frame_lines = {}
  for _, p in ipairs(pairs_) do
    frame_lines[p.begin_lnum] = true
    frame_lines[p.end_lnum] = true
  end

  for _, p in ipairs(pairs_) do
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
    local begin_src_w = vim.fn.strdisplaywidth(
      vim.api.nvim_buf_get_lines(bufnr, p.begin_lnum, p.begin_lnum + 1, false)[1] or ""
    )
    local end_src_w = vim.fn.strdisplaywidth(
      vim.api.nvim_buf_get_lines(bufnr, p.end_lnum, p.end_lnum + 1, false)[1] or ""
    )
    local source_max = begin_src_w > end_src_w and begin_src_w or end_src_w
    local inner = inner_width(vim.fn.strdisplaywidth(p.label), body_max, source_max)

    if p.begin_lnum >= top and p.begin_lnum < bot then
      decorate_top(bufnr, ns, p.begin_lnum, p.lead, p.label, inner)
    end
    if p.end_lnum >= top and p.end_lnum < bot then
      decorate_bottom(bufnr, ns, p.end_lnum, p.end_lead, inner)
    end
    if p.end_lnum > p.begin_lnum + 1 then
      local body_start = math.max(p.begin_lnum + 1, top)
      local body_end = math.min(p.end_lnum - 1, bot - 1)
      if body_start <= body_end then
        local body_lines = vim.api.nvim_buf_get_lines(bufnr, body_start, body_end + 1, false)
        for body_idx, body_line in ipairs(body_lines) do
          local body_row = body_start + body_idx - 1
          if not frame_lines[body_row] then
            decorate_body(bufnr, ns, body_row, body_line, inner, tint)
          end
        end
      end
    end
  end
end

require("organ.modern.render").register("blocks", render)

function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = require("organ.modern.render").ns
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  render(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  register_highlights()
  require("organ.modern.render").attach(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  require("organ.modern.render").detach(bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.blocks")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.blocks") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
