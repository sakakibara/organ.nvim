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

-- Probe once: nvim_buf_set_extmark with `conceal_lines = ""` is the
-- primitive this module relies on (added in nvim 0.11).  On 0.10 the
-- argument is silently ignored; we detect it here and refuse to enter
-- so callers can fall back to the body_fold strategy.
local supported = nil
local function is_supported()
  if supported ~= nil then
    return supported
  end
  local probe_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(probe_buf, 0, -1, false, { "a", "b" })
  local probe_ns = vim.api.nvim_create_namespace("organ_fold_contents_probe")
  local ok = pcall(function()
    vim.api.nvim_buf_set_extmark(probe_buf, probe_ns, 0, 0, {
      end_row = 1,
      conceal_lines = "",
    })
  end)
  if ok then
    -- The extmark accepted; verify it actually conceals by inspecting
    -- the metadata field on get_extmark_by_id.
    local marks = vim.api.nvim_buf_get_extmarks(probe_buf, probe_ns, 0, -1, { details = true })
    supported = #marks == 1 and marks[1][4] and marks[1][4].conceal_lines == ""
  else
    supported = false
  end
  pcall(vim.api.nvim_buf_delete, probe_buf, { force = true })
  return supported
end

M.is_supported = is_supported

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
    -- nvim_buf_set_extmark's `end_row` is 0-indexed INCLUSIVE; the
    -- body range (`r[1]`, `r[2]`) is 1-indexed inclusive.  Both ends
    -- need -1 to convert.  Without the second `-1` the mark spills
    -- onto the heading line that follows and the next heading
    -- vanishes when CONTENTS is active.
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, r[1] - 1, 0, {
      end_row = r[2] - 1,
      conceal_lines = "",
    })
  end
end

function M.enter(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if state[bufnr] or not is_supported() then
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
