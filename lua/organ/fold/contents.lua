-- CONTENTS view via `conceal_lines` extmarks (Emacs-fidelity).
--
-- When `fold.body_fold = false`, body lines share the parent heading's
-- foldlevel, so there's no foldlevel state that hides body without
-- also hiding sub-headings.  Instead, CONTENTS state lays a conceal
-- layer over each section's body line range.  All headings stay
-- visible regardless of depth; body disappears.
--
-- Lifecycle:
--   M.enter(bufnr): place extmarks, save+raise window conceallevel.
--   M.leave(bufnr): drop extmarks, restore conceallevel.
--   M.is_active(bufnr): query.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_fold_contents")
local state = {} -- bufnr -> { saved_conceallevel = N }

-- Body range of every heading section: lines between the heading and
-- the line BEFORE the next heading (any depth).  Sub-headings sit
-- between, so each "body range" is contiguous lines that aren't
-- themselves headings.
local function each_body_range(bufnr)
  local nlines = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, nlines, false)
  local ranges = {}
  local body_start = nil
  for i = 1, nlines do
    local is_heading = (lines[i] or ""):match("^%*+%s") ~= nil
    if is_heading then
      if body_start then
        ranges[#ranges + 1] = { body_start, i - 1 }
        body_start = nil
      end
    elseif not body_start then
      body_start = i
    end
  end
  if body_start then
    ranges[#ranges + 1] = { body_start, nlines }
  end
  return ranges
end

function M.is_active(bufnr)
  return state[bufnr] ~= nil
end

local function place_marks(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, r in ipairs(each_body_range(bufnr)) do
    -- Each contiguous body range becomes one extmark.  end_row in
    -- nvim_buf_set_extmark is the 0-indexed exclusive end row; for a
    -- 1-indexed inclusive last line `r[2]`, that's just `r[2]`.
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, r[1] - 1, 0, {
      end_row = r[2],
      conceal_lines = "",
    })
  end
end

function M.enter(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if state[bufnr] then
    return
  end
  place_marks(bufnr)
  -- Save+raise conceallevel and concealcursor.  Default `concealcursor
  -- = ""` reveals concealed text when the cursor lands on the line --
  -- that would expose body the moment the user does `j` from a
  -- heading.  `nvic` keeps concealment in normal/visual/insert/cmdline.
  local saved_cl = vim.wo.conceallevel
  local saved_cc = vim.wo.concealcursor
  if saved_cl < 2 then
    vim.wo.conceallevel = 2
  end
  vim.wo.concealcursor = "nvic"
  state[bufnr] = { saved_conceallevel = saved_cl, saved_concealcursor = saved_cc }
end

function M.leave(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local s = state[bufnr]
  if not s then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  if vim.wo.conceallevel ~= s.saved_conceallevel then
    vim.wo.conceallevel = s.saved_conceallevel
  end
  if vim.wo.concealcursor ~= s.saved_concealcursor then
    vim.wo.concealcursor = s.saved_concealcursor
  end
  state[bufnr] = nil
end

-- Refresh in place (after a buffer edit).  No-op if not active.
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not state[bufnr] then
    return
  end
  place_marks(bufnr)
end

-- Forget on BufWipeout.
function M.forget(bufnr)
  state[bufnr] = nil
end

return M
