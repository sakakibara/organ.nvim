-- CONTENTS view via `conceal_lines` extmarks (Emacs-fidelity).
--
-- When `fold.body_fold = false`, body lines share the parent heading's
-- foldlevel, so there's no foldlevel state that hides body without
-- also hiding sub-headings.  Instead, CONTENTS state lays a conceal
-- layer over each section's body line range.  All headings stay
-- visible regardless of depth; body disappears.
--
-- CONTENTS is a PER-WINDOW state.  Two splits showing the same buffer
-- can independently be in SHOW_ALL, OVERVIEW, or CONTENTS.  The decoration
-- provider's on_win callback re-applies the buffer's body extmarks to
-- match THIS window's state right before vim lays out its lines, so
-- each pane's draw sees a different extmark set within the same redraw
-- cycle.
--
-- Lifecycle:
--   M.enter(target): place extmarks, save+raise THAT window's
--     conceallevel.  `target` may be a winid (preferred) or a bufnr
--     (back-compat: defaults to current window showing the buffer).
--   M.leave(target): drop extmarks for that window, restore conceallevel.
--   M.is_active(target): query (winid or bufnr).

local M = {}

local NS = vim.api.nvim_create_namespace("organ_fold_contents")
-- Decoration-provider namespace: distinct from NS so the provider's
-- on_win can clear its own work without disturbing user-placed extmarks
-- in NS that shouldn't move (currently none, but future-proofing).
local DECO_NS = vim.api.nvim_create_namespace("organ_fold_contents_deco")
-- Per-window CONTENTS state.  Keyed by winid; value is `true` when
-- that window has CONTENTS active.  Saved-options for restoration on
-- leave() live in `state[bufnr].win_saved[winid]` (one entry per winid
-- in CONTENTS for that buffer).
local _win_active = {}
-- Separate namespace for "this heading is revealed" markers placed
-- on the heading line itself.  Using extmarks lets the marker travel
-- with the heading line under buffer edits (insertions before the
-- heading shift the marker, deletions remove it).  An lnum-keyed Lua
-- table loses correctness as soon as the user edits anywhere above a
-- revealed heading.
local REVEAL_NS = vim.api.nvim_create_namespace("organ_fold_contents_reveal")
local state = {} -- bufnr -> { saved_conceallevel = N }
-- Memoize visible-line distance per (winid, cursor_line, changedtick).
-- statuscolumn renders the same `cur` for every visible line in a
-- redraw, so the cache absorbs ~all repeated work; first line pays
-- the loop, the rest of the visible window is O(1).  Cleared on
-- enter/leave so adding/removing extmarks invalidates correctly
-- (extmark changes don't bump changedtick).
--
-- Keyed by WINDOW, not buffer: two splits showing the same buffer
-- have independent cursors and need independent cache entries.
-- Window-keyed avoids cache thrashing and prevents the dist[] of
-- window A from being read by window B (each entry stays scoped to
-- a single (winid, cur) pair).
local _slnum_cache = {}

-- Drop every cache entry tied to `bufnr` (across all windows showing
-- it).  All buffer-level invalidation paths (place_marks, fold ops,
-- enter / leave) call this so a stale entry can't survive on a
-- non-active window.
local function invalidate_buf_cache(bufnr)
  for winid, entry in pairs(_slnum_cache) do
    if entry.bufnr == bufnr then
      _slnum_cache[winid] = nil
    end
  end
end

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

-- `0` is vim's "current buffer" alias but is truthy in Lua, so the
-- common `b = b or current_buf()` pattern silently keeps `0` and
-- desyncs table-keyed state from real bufnrs (state[0] vs state[1]).
-- Normalize at every entry point that touches `state`.
local function nbuf(b)
  if not b or b == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return b
end

-- Resolve a public-API argument that may be a winid OR a bufnr (or
-- nil/0 for "current") into a (winid, bufnr) pair.  Old call sites
-- pass bufnr; new call sites pass winid.  Cheaply distinguish by
-- asking nvim whether the number is a valid window.
local function resolve(target)
  if not target or target == 0 then
    local winid = vim.api.nvim_get_current_win()
    return winid, vim.api.nvim_win_get_buf(winid)
  end
  if vim.api.nvim_win_is_valid(target) then
    return target, vim.api.nvim_win_get_buf(target)
  end
  -- Treat as bufnr.  Pick the first window currently showing it; if
  -- none, fall back to the current window (caller probably set up the
  -- buffer but it isn't visible yet).
  local bufnr = nbuf(target)
  local wins = vim.fn.win_findbuf(bufnr) or {}
  return wins[1] or vim.api.nvim_get_current_win(), bufnr
end

-- True iff `target` is currently in CONTENTS.  Accepts a winid (true
-- when THAT window is in CONTENTS) or a bufnr (true when ANY window
-- showing it is in CONTENTS -- back-compat for tests that ask buffer
-- questions).
function M.is_active(target)
  if not target or target == 0 then
    return _win_active[vim.api.nvim_get_current_win()] == true
  end
  if vim.api.nvim_win_is_valid(target) then
    return _win_active[target] == true
  end
  return state[nbuf(target)] ~= nil
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

-- Snapshot of currently-revealed heading line numbers, derived
-- from REVEAL_NS extmarks.  Returns a set keyed by 1-based line
-- number (or nil when nothing is revealed).  Buffer edits move the
-- underlying extmarks automatically, so this snapshot stays in
-- sync with current line positions without explicit migration on
-- TextChanged.
local function revealed_lines(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, REVEAL_NS, 0, -1, {})
  if #marks == 0 then
    return nil
  end
  local set = {}
  for _, m in ipairs(marks) do
    set[m[2] + 1] = m[1] -- lnum -> extmark id
  end
  return set
end

-- True when the heading at line `hline` (or any of its ancestor
-- headings) is in the revealed set -- meaning the user pressed `za`
-- on it (or on a containing heading) to reveal the subtree.  When
-- that's the case we skip both the body conceal and the heading's
-- `…` virt_text.  Walks lines upward from hline, tracking outline
-- level: a smaller-level heading is an ancestor; if it's revealed,
-- the descendant body is too.
local function under_revealed_subtree(bufnr, hline, revealed)
  if not revealed then
    return false
  end
  if revealed[hline] then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, hline - 1, false) or {}
  local hline_stars = (vim.api.nvim_buf_get_lines(bufnr, hline - 1, hline, false) or { "" })[1]:match(
    "^(%*+)%s"
  )
  local cur_level = hline_stars and #hline_stars or math.huge
  for i = #lines, 1, -1 do
    local stars = (lines[i] or ""):match("^(%*+)%s")
    if stars then
      local lvl = #stars
      if lvl < cur_level then
        if revealed[i] then
          return true
        end
        cur_level = lvl
      end
    end
  end
  return false
end

local function place_marks(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  local revealed = revealed_lines(bufnr)
  for _, r in ipairs(each_body_range(bufnr)) do
    local hline = heading_above(bufnr, r[1])
    -- Skip the conceal + ellipsis when the user has revealed this
    -- heading (or any ancestor heading) via `za`.
    if hline and under_revealed_subtree(bufnr, hline, revealed) then
      goto continue
    end
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
    -- renders `* H1…` via `emacs_foldtext`; in CONTENTS view the
    -- heading isn't folded (no closed fold), so foldtext never runs
    -- and the line shows raw.  Plant a virt_text ellipsis on the
    -- heading line above each non-empty body range so a heading
    -- whose body is hidden looks the same in CONTENTS as in
    -- OVERVIEW.  Color comes from the per-level heading-title
    -- capture (`@org.heading.title.N.org`) so `…` matches the
    -- heading text it follows -- same rule the foldtext renderer
    -- applies for the trailing decoration.
    if range_has_real_content(bufnr, r) and hline then
      local line = (vim.api.nvim_buf_get_lines(bufnr, hline - 1, hline, false) or {})[1] or ""
      local hl = require("organ.fold").heading_title_hl(line)
      -- `virt_text_pos = "eol"` lands the ellipsis after any
      -- trailing whitespace on the heading line, which surfaces
      -- as a gap (`* H1 …` instead of `* H1…`).  Use "inline" at
      -- the trimmed end of the line content so the ellipsis sits
      -- flush against the last non-blank char, matching foldtext.
      local trimmed = line:match("^(.-)%s*$") or line
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, hline - 1, #trimmed, {
        virt_text = { { "…", hl } },
        virt_text_pos = "inline",
        hl_mode = "combine",
      })
    end
    ::continue::
  end
end

-- Reveal-marker primitives (extmark-tracked so buffer edits don't
-- invalidate the recorded line numbers).  Add: drops a no-op
-- extmark on the heading line; remove: deletes any existing
-- extmark there; toggle: flips presence.  Returns true when the
-- heading is revealed AFTER the operation.
local function reveal_mark_at(bufnr, lnum)
  return vim.api.nvim_buf_get_extmarks(bufnr, REVEAL_NS, { lnum - 1, 0 }, { lnum - 1, -1 }, {})[1]
end
local function reveal_set(bufnr, lnum)
  if reveal_mark_at(bufnr, lnum) then
    return false -- already set, no change
  end
  vim.api.nvim_buf_set_extmark(bufnr, REVEAL_NS, lnum - 1, 0, {})
  return true
end
local function reveal_clear(bufnr, lnum)
  local m = reveal_mark_at(bufnr, lnum)
  if not m then
    return false
  end
  vim.api.nvim_buf_del_extmark(bufnr, REVEAL_NS, m[1])
  return true
end

-- Toggle the per-heading reveal state for CONTENTS view.  Pressing
-- `za` on a heading line removes its body's conceal (and ellipsis)
-- so the user can see the content without leaving CONTENTS; pressing
-- `za` again puts the body back.  Reveal is subtree-deep: any sub-
-- heading body inside the revealed subtree also becomes visible
-- (matches Emacs CONTENTS where subtree expansion shows everything
-- below).
--
-- Reveal state lives on a REVEAL_NS extmark anchored to the heading
-- line.  Buffer edits that insert/delete lines elsewhere shift the
-- extmark with the heading, so a heading the user revealed stays
-- revealed after edits without explicit migration logic.
function M.toggle_heading(bufnr, lnum)
  bufnr = nbuf(bufnr)
  if not state[bufnr] then
    return
  end
  if not reveal_clear(bufnr, lnum) then
    reveal_set(bufnr, lnum)
  end
  invalidate_buf_cache(bufnr)
  place_marks(bufnr)
end

-- True iff the heading at `lnum` currently has its body concealed
-- by a CONTENTS-view extmark (i.e. it has the `…` virt_text marker
-- planted by `place_marks`).  Public so the statuscolumn helper can
-- show closed-fold chevron on concealed headings: in CONTENTS state
-- there's no actual closed FOLD on the heading, so `foldclosed()`
-- returns -1 even when the body is visually hidden -- the chevron
-- needs the extmark presence as its source of truth.  Returns false
-- for non-org buffers, non-CONTENTS state, non-heading lines, and
-- headings whose body is currently revealed (or that have no body).
function M.heading_concealed(bufnr, lnum)
  bufnr = nbuf(bufnr)
  if not state[bufnr] then
    return false
  end
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    NS,
    { lnum - 1, 0 },
    { lnum - 1, -1 },
    { details = true }
  )
  for _, m in ipairs(marks) do
    if m[4] and m[4].virt_text then
      return true
    end
  end
  return false
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
    -- Buffer-local mapping fired but state says CONTENTS isn't
    -- active here.  This used to be a clean "user has another za
    -- mapping; let it run" -- BUT mode "m" re-applies mappings, so
    -- if our own mapping is the one feedkeys re-routes through, we
    -- recurse forever and freeze.  Use "n" (no remap) so vim's
    -- builtin `za` runs directly.  Has happened in practice when
    -- contents.enter was called with `0` (Lua truthy) which keyed
    -- state under 0 instead of the real bufnr -- the keymap was
    -- live, state[real] was nil.
    vim.api.nvim_feedkeys(key, "n", false)
    return
  end
  -- Per-heading actions stay inside CONTENTS.  Off-heading or
  -- non-per-heading actions (zM / zR / zm / zr) leave CONTENTS and
  -- replay the key so the user's normal fold behavior runs.
  local lnum = vim.fn.line(".")
  local line = vim.fn.getline(lnum) or ""
  local on_heading = line:match("^%*+%s") ~= nil
  if on_heading then
    if key == "za" then
      -- CONTENTS-specific toggle: reveal/re-conceal the heading's
      -- body extmark.  fold.cycle (which apply_state's
      -- foldclose/foldopen) is irrelevant here because the body is
      -- hidden via conceal_lines, not folds.
      M.toggle_heading(bufnr, lnum)
      return
    elseif key == "zc" then
      -- Force-conceal: idempotent on already-concealed heading.
      if reveal_clear(bufnr, lnum) then
        invalidate_buf_cache(bufnr)
        place_marks(bufnr)
      end
      return
    elseif key == "zo" then
      -- Force-reveal: idempotent on already-revealed heading.
      if reveal_set(bufnr, lnum) then
        invalidate_buf_cache(bufnr)
        place_marks(bufnr)
      end
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

function M.enter(target)
  if not is_supported() then
    return
  end
  local winid, bufnr = resolve(target)
  if not (winid and bufnr and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  if _win_active[winid] then
    return -- already in CONTENTS for this window
  end
  -- Save THIS window's conceallevel + concealcursor for restoration
  -- on leave().  Default `concealcursor = ""` reveals concealed text
  -- when the cursor lands on the line -- that would expose body the
  -- moment the user does `j` from a heading.  `nvic` keeps
  -- concealment in normal/visual/insert/cmdline.
  local saved_cl = vim.api.nvim_get_option_value("conceallevel", { win = winid })
  local saved_cc = vim.api.nvim_get_option_value("concealcursor", { win = winid })
  if saved_cl < 2 then
    pcall(vim.api.nvim_set_option_value, "conceallevel", 2, { win = winid, scope = "local" })
  end
  pcall(vim.api.nvim_set_option_value, "concealcursor", "nvic", { win = winid, scope = "local" })
  _win_active[winid] = true
  if state[bufnr] then
    -- Buffer-level setup already done by an earlier winid; just record
    -- this winid's per-window saved options for its eventual leave().
    state[bufnr].win_saved[winid] =
      { saved_conceallevel = saved_cl, saved_concealcursor = saved_cc }
    -- Refresh body extmarks against the current buffer state so any
    -- redraw (decoration provider hasn't fired yet) sees them.
    invalidate_buf_cache(bufnr)
    place_marks(bufnr)
    return
  end
  invalidate_buf_cache(bufnr)
  place_marks(bufnr)
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
    saved_fold_keys = saved_fold_keys,
    last_row = vim.fn.line("."),
    win_saved = {
      [winid] = { saved_conceallevel = saved_cl, saved_concealcursor = saved_cc },
    },
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
  -- Buffer edits while CONTENTS is active: re-place the conceal +
  -- ellipsis marks against the new line layout.  Without this, body
  -- ranges that grew/shrunk under inserts/deletes would have stale
  -- conceal extmarks (extmarks track line shifts, but newly-added
  -- body lines wouldn't be covered).  REVEAL_NS markers anchored to
  -- heading lines auto-track, so the user's revealed state survives
  -- edits.  Coalesce via vim.schedule to drop redundant fires
  -- during multi-line operations.
  local refresh_pending = false
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if refresh_pending then
        return
      end
      refresh_pending = true
      vim.schedule(function()
        refresh_pending = false
        if state[bufnr] and vim.api.nvim_buf_is_valid(bufnr) then
          invalidate_buf_cache(bufnr)
          place_marks(bufnr)
        end
      end)
    end,
  })
  state[bufnr].augroup = group
  on_cursor_moved(bufnr)
end

function M.leave(target)
  local winid, bufnr = resolve(target)
  if not bufnr then
    return
  end
  local s = state[bufnr]
  if not s then
    -- _win_active may still hold winid (defensive cleanup).
    _win_active[winid] = nil
    return
  end
  -- Restore THIS window's saved conceallevel + concealcursor.
  local ws = s.win_saved and s.win_saved[winid]
  if ws and vim.api.nvim_win_is_valid(winid) then
    pcall(
      vim.api.nvim_set_option_value,
      "conceallevel",
      ws.saved_conceallevel,
      { win = winid, scope = "local" }
    )
    pcall(
      vim.api.nvim_set_option_value,
      "concealcursor",
      ws.saved_concealcursor,
      { win = winid, scope = "local" }
    )
  end
  if s.win_saved then
    s.win_saved[winid] = nil
  end
  _win_active[winid] = nil
  -- Are any other winids still in CONTENTS for this buffer?  If yes,
  -- keep buffer-level setup (extmarks, augroup, mappings) intact for
  -- those windows.
  local any_left = false
  for w in pairs(s.win_saved or {}) do
    if vim.api.nvim_win_is_valid(w) and _win_active[w] then
      any_left = true
      break
    end
  end
  if any_left then
    -- Refresh extmarks so the remaining winids' next redraw renders
    -- against a current view of body ranges.
    invalidate_buf_cache(bufnr)
    place_marks(bufnr)
    return
  end
  -- Last winid for this buffer left CONTENTS -- tear down buffer-level
  -- state.
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, REVEAL_NS, 0, -1)
  invalidate_buf_cache(bufnr)
  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  end
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
  local winid = vim.api.nvim_get_current_win()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = _slnum_cache[winid]
  if not entry or entry.bufnr ~= bufnr or entry.tick ~= tick or entry.cur ~= cur then
    entry = { bufnr = bufnr, tick = tick, cur = cur, dist = {} }
    _slnum_cache[winid] = entry
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
      -- foldclosed() returns the START of the closed fold containing
      -- `i`, or -1 if `i` is not in a closed fold.  Three cases:
      --   not in any closed fold         -> visible row, count 1
      --   foldstart of a closed fold     -> the fold's display row
      --                                     (a single visible row);
      --                                     count 1, jump past the
      --                                     fold's tail.
      --   inside a closed fold (i > start) -> hidden row; jump past
      --                                     the fold's tail without
      --                                     counting.
      -- Using foldclosed (start) instead of foldclosedend (end) is
      -- what distinguishes case 2 from case 3 -- foldclosedend
      -- returns the same value for both, so the previous version
      -- always counted the fold even when iterating from a position
      -- inside it (double-count when target lnum was the foldstart).
      local fold_start = vim.fn.foldclosed(i)
      if fold_start == -1 then
        visible = visible + 1
        i = i + 1
      elseif fold_start == i then
        visible = visible + 1
        i = vim.fn.foldclosedend(i) + 1
      else
        i = vim.fn.foldclosedend(i) + 1
      end
    end
  end
  entry.dist[lnum] = visible
  return visible
end

-- Drop the cached visible-line distances.  Fold operations that
-- don't bump `changedtick` (cycle_global, foldclose / foldopen)
-- need this to re-render statuscolumn relnum correctly without
-- waiting for a cursor move.
function M.invalidate_visible_cache(bufnr)
  invalidate_buf_cache(nbuf(bufnr))
end

function M.refresh(bufnr)
  bufnr = nbuf(bufnr)
  if not state[bufnr] then
    return
  end
  place_marks(bufnr)
end

-- Forget on BufWipeout.
function M.forget(bufnr)
  state[nbuf(bufnr)] = nil
end

-- Decoration provider: per-window CONTENTS state via on_win swap.  The
-- buffer-level body extmarks placed in NS are buffer-shared, so a
-- naive multi-window setup would render every pane in the same
-- conceal state.  Instead, on EVERY redraw we re-apply the extmarks
-- right before each window's draw -- if the rendering window is in
-- _win_active, place body marks; otherwise clear them.  Vim does
-- layout per window, so each pane sees a different extmark set within
-- the same redraw cycle (verified empirically: extmark state at the
-- moment of on_win is what THAT window's layout uses).
vim.api.nvim_set_decoration_provider(DECO_NS, {
  on_win = function(_, winid, bufnr)
    if not state[bufnr] then
      return false -- no winid showing this buffer is in CONTENTS; nothing to do
    end
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
    if _win_active[winid] then
      place_marks(bufnr)
    end
    return true
  end,
})

-- Cleanup on WinClosed: drop the closed winid from _win_active so we
-- don't keep stale entries around (and so leave() refcount logic for
-- "any winids still active" stays honest).
vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("organ_fold_contents_winclosed", { clear = true }),
  callback = function(args)
    local winid = tonumber(args.match)
    if winid and _win_active[winid] then
      _win_active[winid] = nil
      -- Sweep any state[bufnr].win_saved entry for this winid so the
      -- "any winids left" check on leave() doesn't see a ghost.
      for _, s in pairs(state) do
        if s.win_saved then
          s.win_saved[winid] = nil
        end
      end
    end
  end,
})

return M
