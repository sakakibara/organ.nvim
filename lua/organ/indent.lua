-- Visual auto-indent (org-indent-mode equivalent) for organ.nvim.
--
-- Body rows of a level-N section get an inline virt-text prefix sized
-- so the first body byte renders at the title-text column of its
-- enclosing headline.  The heading line itself takes a pad of
-- (N-1) * shift_per_level when stars render as literal `*` characters,
-- and no pad when stars are visually replaced (modern bullets or
-- stars.hide), since those modes already convey level via their own
-- conceal-as-spaces treatment.
--
-- Runs as an `organ.decoration` provider: `on_win` walks the tree-sitter
-- `headline` nodes overlapping the visible window range and assigns an
-- effective level to every row in `[topline, botline]`, with the
-- cascade through nested headlines reset by each same-or-higher-level
-- sibling.  `on_line` reads the frame-local row map and emits an
-- ephemeral inline virt_text extmark for the current row.  The tree is
-- parsed once per buffer per redraw by organ.decoration and shared with
-- the other decoration providers.
--
-- Toggle is per-buffer (not filetype-global): the effective `indent.enabled`
-- value for the buffer (global + buf-local overrides via
-- `organ.buf_config`) gates the provider's `enabled` callback, so
-- unrelated org buffers stay untouched until the user flips the bit via
-- `:Org toggle indent.enabled` or sets `cfg.indent.enabled = true` for
-- auto-attach in the ftplugin.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_indent")
M._ns = NS

-- Per-buffer attach state.  Kept as a fast-path mirror of
-- `buf_config.read(bufnr, "indent.enabled")` so the decoration provider's
-- on_win/on_line callbacks don't have to consult the merged config on
-- every redraw.  Writes go through attach/detach; the buf_config
-- reapply hook also keeps this in sync when the user flips the bit
-- via `:Org toggle indent.enabled`.
M._attached = {}

-- Empty-table sentinel.  The memory-probe test asserts
-- `tablen(indent._timers) == 0` to catch per-buffer timer leaks; the
-- on_win design has no timers, but the assertion stays meaningful
-- because the table stays empty.
M._timers = {}

local function bcfg(bufnr, path)
  return require("organ.buf_config").read(bufnr, path)
end

local function get_config(bufnr)
  return bcfg(bufnr, "indent") or {}
end

-- True when the headline's leading stars are visually replaced (modern
-- bullets cycling glyphs, or stars.hide concealing them as spaces).
-- Under either mode the rendered title sits at column L+2 already, so
-- the heading row needs no virt-text pad and the body must align with
-- the title (column L+2, i.e. body pad = L + 1).  `modern.bullets` may
-- be `true` or a config table; both are truthy.
local function stars_visually_hidden(bufnr)
  if bcfg(bufnr, "modern.bullets") then
    return true
  end
  if bcfg(bufnr, "stars.hide") == true then
    return true
  end
  return false
end

-- Line predicates mirroring organ.indentexpr: these classify the rows that
-- the indentexpr gives a real `planning_indent` to (planning lines and
-- drawers), so the virtual pad can absorb that real indent instead of
-- stacking on top of it.  Block bodies are deliberately excluded -- their
-- indentation is literal content, not adaptive.
local function is_planning(l)
  return l:match("^%s*[Ss][Cc][Hh][Ee][Dd][Uu][Ll][Ee][Dd]:") ~= nil
    or l:match("^%s*[Dd][Ee][Aa][Dd][Ll][Ii][Nn][Ee]:") ~= nil
    or l:match("^%s*[Cc][Ll][Oo][Ss][Ee][Dd]:") ~= nil
end
local function is_drawer_open(l)
  return l:match("^%s*:[%w_-]+:%s*$") ~= nil
end
local function is_drawer_close(l)
  return l:match("^%s*:[Ee][Nn][Dd]:%s*$") ~= nil
end
local function is_block_open(l)
  return l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") ~= nil
end
local function is_block_close(l)
  return l:match("^%s*#%+[Ee][Nn][Dd]_") ~= nil
end

-- Frame-local row map: frame_map[row] = pad_string.  Reset at the
-- start of every on_win call; read by on_line for the same frame.
-- Rows at level 1 (no indent) are absent.
local frame_map = {}

-- Build the frame_map by walking buffer lines directly: every line
-- whose first byte is `*` (followed by a space or end-of-line) opens
-- a section at its star-count level; every subsequent line until the
-- next heading inherits that level as a "body" row.  No tree-sitter
-- dependency -- the prior treesitter-backed walk returned stale trees
-- when invoked from a fast (on_lines) context (the LanguageTree edit
-- bookkeeping hadn't caught up to the current buffer yet), so undo /
-- redo could land marks that matched the PRE-undo outline against
-- the POST-undo line numbers, leaving some body rows un-padded.
--
-- Heading pad (heading row): (L-1)*shift under literal stars; 0 when
-- stars are visually replaced (modern.bullets / stars.hide supply
-- N-1 conceal-spaces of their own).
-- Body pad (rows under the heading until the next heading): aligns
-- the body's first byte with the heading title column.  Under literal
-- stars the title sits at (L-1)*shift + L + 1 bytes in (heading pad
-- + L stars + space); under stars-hidden modes the rendered title
-- starts at column L+2, so the body pad is L+1.
local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not M._attached[bufnr] then
    return
  end
  local cfg = get_config(bufnr)
  local shift = cfg.shift_per_level or 2
  local hide_stars = stars_visually_hidden(bufnr)

  local n = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  local current_level = 0
  local in_drawer, in_block = false, false
  for i, txt in ipairs(lines) do
    local row = i - 1
    local stars = txt:match("^(%*+)%s") or txt:match("^(%*+)$")
    if stars then
      local level = #stars
      current_level = level
      in_drawer, in_block = false, false -- drawers/blocks never span a heading
      if row >= topline and row <= botline then
        local pad_size = hide_stars and 0 or ((level - 1) * shift)
        if pad_size > 0 then
          frame_map[row] = string.rep(" ", pad_size)
        end
      end
    elseif current_level > 0 then
      -- Absorb real leading whitespace only for the lines the indentexpr
      -- gives an adaptive `planning_indent` to (planning + drawer edges +
      -- drawer interior), never inside a block.  Otherwise the inline pad
      -- stacks on top of that real indent and the line overshoots the title.
      -- List items and paragraphs keep their (structural) real indent on top
      -- of the uniform pad, matching Emacs org-indent.
      local absorb = not in_block
        and (is_planning(txt) or is_drawer_open(txt) or is_drawer_close(txt) or in_drawer)
      if row >= topline and row <= botline then
        -- Title-text column: where the first byte must render to sit under
        -- the heading title.
        local target = hide_stars and (current_level + 1)
          or ((current_level - 1) * shift + current_level + 1)
        local pad_size = target
        if absorb then
          pad_size = target - #(txt:match("^%s*") or "")
        end
        if pad_size > 0 then
          frame_map[row] = string.rep(" ", pad_size)
        end
      end
      -- Update block/drawer state AFTER classifying this row.
      if is_block_open(txt) then
        in_block = true
      elseif is_block_close(txt) then
        in_block = false
      elseif not in_block then
        if is_drawer_close(txt) then
          in_drawer = false
        elseif is_drawer_open(txt) then
          in_drawer = true
        end
      end
    end
  end
end

-- Place persistent inline virt_text extmarks for `bufnr`, one per row
-- whose enclosing section has a non-zero pad.  Clears any previous
-- marks in our namespace first so a structural change doesn't leave
-- stale pads behind.
local function place_marks(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  on_win(bufnr, 0, 0, n - 1)
  local cfg = get_config(bufnr)
  local hl = cfg.hl_group or "Conceal"
  for row, pad in pairs(frame_map) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
      virt_text = { { pad, hl } },
      virt_text_pos = "inline",
      right_gravity = false,
      -- The indent is the outermost virtual left margin, so it must render
      -- leftmost. Inline virt_text at the same column renders lower priority
      -- first (further left), so keep this below every decoration that draws
      -- at column 0 -- notably modern block frames (priority 200), whose `│`
      -- side bar would otherwise sit left of the pad and push the body out.
      priority = 1,
    })
  end
end

-- Last `changedtick` we placed marks for, per buffer.  Used by the
-- decoration-provider trigger to refresh exactly once per advancing
-- tick (so a burst of edits within one redraw cycle coalesces into a
-- single full walk, and the trigger no-ops on cycles where the
-- buffer didn't change).
local _last_refresh_tick = {}

local function maybe_refresh(bufnr)
  if not M._attached[bufnr] then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if _last_refresh_tick[bufnr] == tick then
    return
  end
  _last_refresh_tick[bufnr] = tick
  place_marks(bufnr)
end

-- Refresh trigger.  A decoration provider's `on_buf` is the right
-- mechanism here: it fires once per redraw cycle, AFTER nvim has
-- applied any pending buffer mutations and BEFORE the screen is
-- painted, regardless of HOW the buffer was mutated.  `changedtick`
-- advances for every mutation -- normal edits, undo, redo, even
-- persistent-undo traversal back through prior-session state -- so
-- tick-based dedup means the refresh runs exactly once per change.
--
-- Earlier this module subscribed via `nvim_buf_attach`'s `on_lines`,
-- but that callback isn't fired for every code path that mutates the
-- buffer (notably persistent-undo replay across session boundaries
-- advances changedtick without driving on_lines), which left
-- pads visibly stale after `u` past the buffer's loaded state.
-- on_buf catches every mutation path because every mutation produces
-- a redraw.
do
  local PROVIDER_NS = vim.api.nvim_create_namespace("organ_indent_provider")
  vim.api.nvim_set_decoration_provider(PROVIDER_NS, {
    on_buf = function(_, bufnr, _tick)
      maybe_refresh(bufnr)
    end,
  })
end

-- Public synchronous refresh.  Tests and external callers (e.g. the
-- buf_config reapply hook) use this to force the walk without waiting
-- for the next redraw.
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  _last_refresh_tick[bufnr] = vim.api.nvim_buf_get_changedtick(bufnr)
  place_marks(bufnr)
end

M._frame_map = function()
  return frame_map
end

function M.attach(bufnr)
  if M._attached[bufnr] then
    return
  end
  M._attached[bufnr] = true
  -- on_lines is the sync path: structure ops (promote / demote, etc.)
  -- need pads updated BEFORE nvim's next redraw to avoid a one-frame
  -- stale-width flicker.  The decoration provider's on_buf is the
  -- safety net for mutation paths on_lines misses (persistent undo
  -- across session boundaries advances changedtick without driving
  -- on_lines).  Both go through maybe_refresh, which tick-dedups so a
  -- single mutation doesn't refresh twice.
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b, _tick, first, last_old, last_new)
      if not M._attached[b] then
        return true
      end
      -- Sync refresh when the edit could have changed the section
      -- structure:
      --   * line count changed -- a heading row may have been added
      --     or removed (we can't inspect the deleted content, so
      --     refresh whenever rows came or went)
      --   * any new row starts with `*` -- a heading was touched in
      --     place (promote / demote / typing a leading star)
      -- Body-only same-line edits skip the sync walk; the decoration
      -- provider's on_buf takes care of any per-redraw drift.  Keeps
      -- per-keystroke cost in long buffers near zero
      -- (decoration_perf_test asserts ~5ms).
      if last_old ~= last_new then
        maybe_refresh(b)
        return
      end
      for r = first, last_new - 1 do
        local txt = vim.api.nvim_buf_get_lines(b, r, r + 1, false)[1] or ""
        if txt:sub(1, 1) == "*" then
          maybe_refresh(b)
          return
        end
      end
    end,
    -- nvim drops a buffer listener that doesn't define `on_reload` when
    -- the buffer's contents are reloaded -- autoread / `:checktime`
    -- picking up an on-disk rewrite, or undoing back across the entry
    -- that reload recorded -- and fires its `on_detach` instead.
    -- Without this callback the module concluded the buffer had
    -- detached while `indent.enabled` was still true, so every refresh
    -- path short-circuited on `M._attached` and the pads placed before
    -- the reload were neither cleared nor recomputed.  A reload swaps
    -- the whole buffer, so rebuild every pad.
    on_reload = function(_, b)
      M.refresh(b)
    end,
    on_detach = function(_, b)
      M._attached[b] = nil
      _last_refresh_tick[b] = nil
    end,
  })
  M.refresh(bufnr)
end

function M.detach(bufnr)
  if not M._attached[bufnr] then
    return
  end
  M._attached[bufnr] = nil
  _last_refresh_tick[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  end
end

function M.toggle(bufnr)
  if M._attached[bufnr] then
    M.detach(bufnr)
  else
    M.attach(bufnr)
  end
end

-- Reapply hook: when buf_config.set / unset / reset fires, re-evaluate
-- the buffer's effective `indent.enabled` value and attach/detach to
-- match.  Idempotent: attach/detach are no-ops when the state already
-- matches the request.
require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local want = require("organ.buf_config").read(bufnr, "indent.enabled") == true
  if want then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
