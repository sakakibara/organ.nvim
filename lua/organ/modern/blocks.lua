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

local function decorate_line(bufnr, lnum0, leading, kind, suffix, is_end)
  local label = kind
  if not is_end and suffix and suffix ~= "" then
    -- Strip leading whitespace from suffix; first whitespace-separated
    -- token is the language (for src_block) or first param.
    local first = suffix:match("^%s*(%S+)")
    if first then
      label = first
    end
  end
  local glyph_top = "┌── "
  local glyph_bot = "└── "
  local rule =
    " ──────────────────────────────"
  local virt_text
  if is_end then
    virt_text = { { leading .. glyph_bot .. rule, "@organ.modern.block_frame" } }
  else
    virt_text = {
      { leading .. glyph_top, "@organ.modern.block_frame" },
      { label, "@organ.modern.block_label" },
      { rule, "@organ.modern.block_frame" },
    }
  end
  -- Hide the original line bytes via conceal — extmark with conceal=""
  -- across the whole line range.
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
  for i, line in ipairs(lines) do
    local lead, kind, suffix = line:match(BEGIN_PAT)
    if lead then
      decorate_line(bufnr, i - 1, lead, kind, suffix, false)
    else
      lead, kind = line:match(END_PAT)
      if lead then
        decorate_line(bufnr, i - 1, lead, kind, "", true)
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

  apply(bufnr)
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
