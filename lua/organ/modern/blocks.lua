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

-- Inner cols of the box (display width between the left/right corners).
-- Top fills it with: LBL_LEAD + label + LBL_TAIL + TRAILING_RULE_LEN
-- dashes.  Body / bottom must match.
local LBL_LEAD_W = vim.fn.strdisplaywidth(LBL_LEAD)
local LBL_TAIL_W = vim.fn.strdisplaywidth(LBL_TAIL)
local function inner_width(label_width)
  return LBL_LEAD_W + label_width + LBL_TAIL_W + TRAILING_RULE_LEN
end

local function decorate_top(bufnr, lnum0, leading, label)
  local trailing = LBL_TAIL .. string.rep(H, TRAILING_RULE_LEN) .. TR
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

local function decorate_bottom(bufnr, lnum0, leading, label_width)
  local rule = string.rep(H, inner_width(label_width))
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
-- end byte adds the trailing padding + right bar.  Lines too long for
-- the box (content >= inner_width - 1) get only the left bar -- forcing
-- a right bar past the end would visually mangle the box, so we accept
-- the open right side on overflow.
local function decorate_body(bufnr, lnum0, source, label_width)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum0, 0, {
    virt_text = { { LSIDE, "@organ.modern.block_frame" } },
    virt_text_pos = "inline",
  })
  -- Total cols available BETWEEN the bars = inner_width(label_width).
  -- After LSIDE (2 cols) the source content starts; we need
  -- inner_width - 1 - source_display cols of trailing pad before V.
  local pad = inner_width(label_width) - 1 - vim.fn.strdisplaywidth(source)
  if pad < 0 then
    return
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
  -- Stack of pending begins so an end line can recover the matching
  -- begin's label width and produce a bottom line of identical
  -- visual width.  Pairs by `kind` so nested blocks (greater_block
  -- containing src_block etc.) match correctly.  begin's lnum is
  -- also tracked so we can decorate body rows on the way out.
  local begins = {}
  -- Lines that already get top/bottom decoration -- skip body
  -- decoration on these so the side bar doesn't stack over the
  -- top/bottom overlay.
  local frame_lines = {}
  for i, line in ipairs(lines) do
    local lead, kind, suffix = line:match(BEGIN_PAT)
    if lead then
      local label = compute_label(kind, suffix)
      table.insert(begins, {
        kind = kind,
        lnum0 = i - 1,
        label_width = vim.fn.strdisplaywidth(label),
      })
      decorate_top(bufnr, i - 1, lead, label)
      frame_lines[i - 1] = true
    else
      lead, kind = line:match(END_PAT)
      if lead then
        -- Pop topmost begin with matching kind.  Stale begins
        -- (kind mismatch caused by malformed source) stay on the
        -- stack; the end falls back to its own kind for the width.
        local matched, label_width
        for j = #begins, 1, -1 do
          if begins[j].kind == kind then
            matched = begins[j]
            label_width = matched.label_width
            table.remove(begins, j)
            break
          end
        end
        if not label_width then
          label_width = vim.fn.strdisplaywidth(kind)
        end
        decorate_bottom(bufnr, i - 1, lead, label_width)
        frame_lines[i - 1] = true
        -- Decorate body lines between begin and end with the side
        -- bar.  Nested begin / end lines (also marked in frame_lines)
        -- are skipped so their own top/bottom decoration shows
        -- without a redundant prefix.
        if matched then
          for body = matched.lnum0 + 1, i - 2 do
            if not frame_lines[body] then
              decorate_body(bufnr, body, lines[body + 1] or "", label_width)
            end
          end
        end
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
