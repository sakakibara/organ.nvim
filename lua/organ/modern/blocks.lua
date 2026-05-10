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

local TOP_GLYPH = "┌── "
-- BOT_GLYPH is just the corner; everything after is continuous
-- horizontal so the bottom reads as an unbroken rule (no "disjointed
-- space" between the corner and the dashes).  Top retains the "── "
-- visual padding because it surrounds the label.
local BOT_GLYPH = "└"
local SIDE_GLYPH = "│ " -- left side bar + 1 col of inner padding
local TRAILING_RULE_LEN = 30 -- dashes after the (label + space) on the begin line

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

local function decorate_top(bufnr, lnum0, leading, label)
  local trailing_rule = " " .. string.rep("─", TRAILING_RULE_LEN)
  local virt_text = {
    { leading .. TOP_GLYPH, "@organ.modern.block_frame" },
    { label, "@organ.modern.block_label" },
    { trailing_rule, "@organ.modern.block_frame" },
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
  -- Match the top's total display width.  Top is `TOP_GLYPH + label
  -- + " " + 30 dashes` = 4 + label + 1 + 30 cols.  Bottom is `└` + N
  -- dashes; pick N so the totals match -> N = 3 + label + 1 + 30.
  local rule_len = 3 + label_width + 1 + TRAILING_RULE_LEN
  local rule = string.rep("─", rule_len)
  local virt_text = {
    { leading .. BOT_GLYPH .. rule, "@organ.modern.block_frame" },
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

-- Decorate a body line with the left side bar (`│ ` prefix).  The
-- source line is left intact; an inline virt_text at col 0 pushes the
-- existing content right by 2 visual cols, leaving the bar to render
-- in the leftmost column.  Begin / end lines of nested blocks are
-- skipped at the call site -- they get their own top/bottom decoration
-- and stacking `│ ` over an overlay extmark looks wrong.
local function decorate_body(bufnr, lnum0)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, lnum0, 0, {
    virt_text = { { SIDE_GLYPH, "@organ.modern.block_frame" } },
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
              decorate_body(bufnr, body)
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
