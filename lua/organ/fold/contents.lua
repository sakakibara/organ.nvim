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
-- Memoize visible-line distance per (bufnr, cursor_line, changedtick).
-- statuscolumn renders the same `cur` for every visible line in a
-- redraw, so the cache absorbs ~all repeated work; first line pays
-- the loop, the rest of the visible window is O(1).  Cleared on
-- enter/leave so adding/removing extmarks invalidates correctly
-- (extmark changes don't bump changedtick).
local _slnum_cache = {}

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
-- themselves headings.  Pre-first-heading lines (`#+title:`,
-- `#+author:`, etc.) are NOT body -- they live outside the outline
-- and stay visible in CONTENTS view, mirroring Emacs.
local function each_body_range(bufnr)
  local nlines = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, nlines, false)
  local ranges = {}
  local body_start = nil
  local seen_heading = false
  for i = 1, nlines do
    local is_heading = (lines[i] or ""):match("^%*+%s") ~= nil
    if is_heading then
      seen_heading = true
      if body_start then
        ranges[#ranges + 1] = { body_start, i - 1 }
        body_start = nil
      end
    elseif seen_heading and not body_start then
      body_start = i
    end
  end
  if body_start and seen_heading then
    ranges[#ranges + 1] = { body_start, nlines }
  end
  return ranges
end

function M.is_active(bufnr)
  return state[bufnr] ~= nil
end

-- Whether body range `r` (1-indexed inclusive) hides anything
-- non-whitespace.  All-blank ranges aren't worth flagging with an
-- ellipsis on the heading -- mirrors the same "no real content"
-- check `emacs_foldtext` applies to closed folds in OVERVIEW.
local function range_has_real_content(bufnr, r)
  local lines = vim.api.nvim_buf_get_lines(bufnr, r[1] - 1, r[2], false) or {}
  for _, l in ipairs(lines) do
    if l:match("%S") then
      return true
    end
  end
  return false
end

-- Find the heading line above body range r[1].  Headings can be
-- separated from their body by blanks / drawers / planning lines,
-- so scan upward for `^*+\s`.  Returns nil when the first body
-- range starts before any heading (shouldn't happen --
-- `each_body_range` already filters those, but be defensive).
local function heading_above(bufnr, body_start)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, body_start - 1, false) or {}
  for i = #lines, 1, -1 do
    if (lines[i] or ""):match("^%*+%s") then
      return i
    end
  end
  return nil
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
    -- Visual parity with OVERVIEW state: a closed-fold heading
    -- renders "* H1 …" via `emacs_foldtext`; in CONTENTS view the
    -- heading isn't folded (no closed fold), so foldtext never runs
    -- and the line shows raw.  Plant a virt_text ellipsis on the
    -- heading line above each non-empty body range so a heading
    -- whose body is hidden looks the same in CONTENTS as in
    -- OVERVIEW.  `Folded` hl picks up the same `winhighlight`
    -- remap (`Folded:OrgFolded`) so the bg is transparent.
    if range_has_real_content(bufnr, r) then
      local hline = heading_above(bufnr, r[1])
      if hline then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, hline - 1, 0, {
          virt_text = { { " …", "Folded" } },
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      end
    end
  end
end

-- True when row `lnum` (1-indexed) is covered by one of our
-- conceal_lines extmarks.
local function is_concealed_line(bufnr, lnum)
  local row = lnum - 1
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    NS,
    { row, 0 },
    { row, -1 },
    { details = true, overlap = true }
  )
  for _, m in ipairs(marks) do
    local opts = m[4]
    local end_row = opts.end_row or m[2]
    if m[2] <= row and row <= end_row and opts.conceal_lines == "" then
      return true
    end
  end
  return false
end

local function next_visible(bufnr, from)
  local last = vim.api.nvim_buf_line_count(bufnr)
  for i = from, last do
    if not is_concealed_line(bufnr, i) then
      return i
    end
  end
  return nil
end

local function prev_visible(bufnr, from)
  for i = from, 1, -1 do
    if not is_concealed_line(bufnr, i) then
      return i
    end
  end
  return nil
end

-- Cursor-skip is implemented on CursorMoved instead of keymaps so
-- every motion users actually use is covered: j/k, arrows, gj/gk,
-- search, gg/G, ]] / [[, marks, mouse clicks, custom remaps, ...
-- The user's keymaps stay untouched.  Visual / insert / op-pending
-- modes are not redirected -- we only want to nudge plain navigation.
local function on_cursor_moved(bufnr)
  local s = state[bufnr]
  if not s or s.redirecting then
    return
  end
  if vim.api.nvim_get_mode().mode ~= "n" then
    return
  end
  local row = vim.fn.line(".")
  if not is_concealed_line(bufnr, row) then
    s.last_row = row
    return
  end
  local prev = s.last_row or row
  local target
  if row >= prev then
    target = next_visible(bufnr, row + 1) or prev_visible(bufnr, row - 1)
  else
    target = prev_visible(bufnr, row - 1) or next_visible(bufnr, row + 1)
  end
  if not target or is_concealed_line(bufnr, target) then
    return
  end
  s.redirecting = true
  pcall(vim.api.nvim_win_set_cursor, 0, { target, vim.fn.col(".") - 1 })
  s.redirecting = false
  s.last_row = target
end

-- Snapshot a buffer-local mapping so it can be restored verbatim
-- after we replace it.  Returns nil when no buffer-local mapping
-- exists (vim's default or a global mapping handles the key) -- in
-- that case `vim.keymap.del { buffer = bufnr }` on leave is enough.
local function snapshot_buf_mapping(bufnr, mode, lhs)
  local maps = vim.api.nvim_buf_get_keymap(bufnr, mode)
  for _, m in ipairs(maps) do
    if m.lhs == lhs then
      return m
    end
  end
  return nil
end

local function restore_buf_mapping(bufnr, mode, lhs, snap)
  pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
  if not snap then
    return
  end
  local opts = {
    buffer = bufnr,
    silent = snap.silent == 1,
    noremap = snap.noremap == 1,
    expr = snap.expr == 1,
    nowait = snap.nowait == 1,
    desc = snap.desc,
  }
  if snap.callback then
    pcall(vim.keymap.set, mode, lhs, snap.callback, opts)
  elseif snap.rhs and snap.rhs ~= "" then
    pcall(vim.keymap.set, mode, lhs, snap.rhs, opts)
  end
end

-- Public fold-action entry point.  Single function users can map
-- directly so non-recursive aliases (`vim.keymap.set("n", "<F3>",
-- function() require("organ.fold.contents").fold_action("za") end)`)
-- bypass vim's mapping machinery into THIS function rather than
-- vim's default fold command.  Outside CONTENTS state it just
-- feeds `key` so the user's normal fold behavior runs.
function M.fold_action(key)
  local bufnr = vim.api.nvim_get_current_buf()
  if not state[bufnr] then
    vim.api.nvim_feedkeys(key, "m", false)
    return
  end
  -- Per-heading actions stay inside CONTENTS.  Off-heading or
  -- non-per-heading actions (zM / zR / zm / zr) leave CONTENTS and
  -- replay the key so the user's normal fold behavior runs.
  local lnum = vim.fn.line(".")
  local line = vim.fn.getline(lnum) or ""
  local on_heading = line:match("^%*+%s") ~= nil
  local fold = require("organ.fold")
  if on_heading then
    if key == "za" then
      fold.cycle(0, lnum)
      return
    elseif key == "zc" then
      fold.set_heading_state(0, lnum, "folded")
      return
    elseif key == "zo" then
      fold.set_heading_state(0, lnum, "subtree")
      return
    end
  end
  M.leave(bufnr)
  vim.schedule(function()
    vim.api.nvim_feedkeys(key, "m", false)
  end)
end

-- Buffer-local fold keymaps installed while CONTENTS is active.
-- Each binding dispatches through `M.fold_action` so the public API
-- and the buffer-local default share identical semantics.  Descs are
-- the labels which-key (and `:Telescope keymaps`, etc.) show; keep
-- them human-readable so the popup explains what each key actually
-- does in CONTENTS state instead of `organ CONTENTS: za`.
local FOLD_KEYS = {
  za = "Cycle heading (CONTENTS)",
  zc = "Close heading (CONTENTS)",
  zo = "Open heading subtree (CONTENTS)",
  zM = "Close all (exits CONTENTS)",
  zR = "Open all (exits CONTENTS)",
  zm = "Decrement foldlevel (exits CONTENTS)",
  zr = "Increment foldlevel (exits CONTENTS)",
}

function M.enter(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if state[bufnr] or not is_supported() then
    return
  end
  _slnum_cache[bufnr] = nil
  place_marks(bufnr)
  -- Save+raise conceallevel and concealcursor on every window
  -- currently showing this buffer.  Default `concealcursor = ""`
  -- reveals concealed text when the cursor lands on the line --
  -- that would expose body the moment the user does `j` from a
  -- heading.  `nvic` keeps concealment in normal/visual/insert/
  -- cmdline.  Snapshot one window's value as the "saved" baseline
  -- (typical case: the buffer is in one window).
  local wins = vim.fn.win_findbuf(bufnr) or {}
  local probe_win = wins[1] or 0
  local saved_cl = vim.api.nvim_get_option_value("conceallevel", { win = probe_win })
  local saved_cc = vim.api.nvim_get_option_value("concealcursor", { win = probe_win })
  for _, win in ipairs(wins) do
    if vim.api.nvim_get_option_value("conceallevel", { win = win }) < 2 then
      pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = win })
    end
    pcall(vim.api.nvim_set_option_value, "concealcursor", "nvic", { win = win })
  end
  -- Snapshot every prior buffer-local fold mapping we're about to
  -- replace, so leave() restores the user's exact mapping (including
  -- callback / rhs / silent / noremap / expr / desc) instead of just
  -- deleting our override and leaving the slot empty.
  local saved_fold_keys = {}
  for key, desc in pairs(FOLD_KEYS) do
    saved_fold_keys[key] = snapshot_buf_mapping(bufnr, "n", key)
    pcall(vim.keymap.set, "n", key, function()
      M.fold_action(key)
    end, {
      buffer = bufnr,
      desc = desc,
    })
  end
  state[bufnr] = {
    saved_conceallevel = saved_cl,
    saved_concealcursor = saved_cc,
    saved_fold_keys = saved_fold_keys,
    last_row = vim.fn.line("."),
  }
  -- Defensive autocmd surface so state never leaks past the
  -- circumstances it was meant for.  Buffer-local so the events fire
  -- only for THIS buffer:
  --   CursorMoved / BufWinEnter -> redirect cursor off concealed body
  --     after any motion or window/pane re-entry (j/k/arrows/search/
  --     gg/G/mouse/wincmd/tmux focus/...).
  --   FileType -> if user (or another plugin) changes filetype away
  --     from org, leave CONTENTS so saved window options are restored
  --     and our extmarks/autocmd are cleared.
  --   BufWipeout -> tear down state on buffer wipe; nothing to
  --     restore on a dead buffer, so just forget.
  local group = vim.api.nvim_create_augroup("organ_fold_contents_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      on_cursor_moved(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    buffer = bufnr,
    callback = function()
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype ~= "org" then
        M.leave(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.forget(bufnr)
    end,
  })
  state[bufnr].augroup = group
  on_cursor_moved(bufnr)
end

function M.leave(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local s = state[bufnr]
  if not s then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  _slnum_cache[bufnr] = nil
  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  end
  -- Restore window options ONLY on windows actually showing this
  -- buffer right now -- writing vim.wo blindly would poison whichever
  -- buffer's window happens to be current.
  for _, win in ipairs(vim.fn.win_findbuf(bufnr) or {}) do
    pcall(vim.api.nvim_set_option_value, "conceallevel", s.saved_conceallevel, { win = win })
    pcall(vim.api.nvim_set_option_value, "concealcursor", s.saved_concealcursor, { win = win })
  end
  -- Restore prior buffer-local fold mappings (or remove ours when
  -- there was no prior mapping; user's global mapping kicks back in
  -- automatically once our buffer-local is gone).
  if s.saved_fold_keys then
    for key, snap in pairs(s.saved_fold_keys) do
      restore_buf_mapping(bufnr, "n", key, snap)
    end
  end
  state[bufnr] = nil
end

-- Visual-line statuscolumn helper.  Returns what should appear in the
-- line-number slot for buffer line `lnum`, computed from VISIBLE
-- (non-concealed) line distance instead of buffer-line distance.
-- Drop into a custom statuscolumn so relnum stays correct under
-- CONTENTS view (and any other conceal_lines layer this module
-- applies in the future).  Outside CONTENTS state, no extmarks are
-- present, every line is visible, and the result matches vim's
-- built-in `number` / `relativenumber`.
--   relative = true  -> relnum (current line shows absolute lnum;
--                       others show visible distance)
--   relative = false -> absolute lnum
function M.statuscolumn_lnum(lnum, relative)
  if not relative then
    return lnum
  end
  local cur = vim.fn.line(".")
  if lnum == cur then
    return lnum
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = _slnum_cache[bufnr]
  if not entry or entry.tick ~= tick or entry.cur ~= cur then
    entry = { tick = tick, cur = cur, dist = {} }
    _slnum_cache[bufnr] = entry
  end
  local cached = entry.dist[lnum]
  if cached ~= nil then
    return cached
  end
  local lo, hi = math.min(lnum, cur), math.max(lnum, cur)
  local visible = 0
  local i = lo + 1
  while i <= hi do
    if is_concealed_line(bufnr, i) then
      i = i + 1
    else
      local fold_end = vim.fn.foldclosedend(i)
      if fold_end > 0 then
        visible = visible + 1
        i = fold_end + 1
      else
        visible = visible + 1
        i = i + 1
      end
    end
  end
  entry.dist[lnum] = visible
  return visible
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
