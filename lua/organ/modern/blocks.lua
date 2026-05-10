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
local BOT_GLYPH = "└── "
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
  -- Match the top's total width: top is `leading + TOP_GLYPH + label
  -- + " " + 30 dashes`.  Bottom replaces `label + " "` with dashes of
  -- the same display width so the two lines line up vertically.
  local fill_len = label_width + 1
  local rule = string.rep("─", fill_len + TRAILING_RULE_LEN)
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
  -- containing src_block etc.) match correctly.
  local begins = {}
  for i, line in ipairs(lines) do
    local lead, kind, suffix = line:match(BEGIN_PAT)
    if lead then
      local label = compute_label(kind, suffix)
      table.insert(begins, {
        kind = kind,
        label_width = vim.fn.strdisplaywidth(label),
      })
      decorate_top(bufnr, i - 1, lead, label)
    else
      lead, kind = line:match(END_PAT)
      if lead then
        -- Pop topmost begin with matching kind.  Stale begins
        -- (kind mismatch caused by malformed source) stay on the
        -- stack; the end falls back to its own kind for the width.
        local label_width
        for j = #begins, 1, -1 do
          if begins[j].kind == kind then
            label_width = begins[j].label_width
            table.remove(begins, j)
            break
          end
        end
        if not label_width then
          label_width = vim.fn.strdisplaywidth(kind)
        end
        decorate_bottom(bufnr, i - 1, lead, label_width)
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
