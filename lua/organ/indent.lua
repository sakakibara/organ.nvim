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
  for i, txt in ipairs(lines) do
    local row = i - 1
    local stars = txt:match("^(%*+)%s") or txt:match("^(%*+)$")
    if stars then
      local level = #stars
      current_level = level
      if row >= topline and row <= botline then
        local pad_size = hide_stars and 0 or ((level - 1) * shift)
        if pad_size > 0 then
          frame_map[row] = string.rep(" ", pad_size)
        end
      end
    elseif current_level > 0 then
      if row >= topline and row <= botline then
        local pad_size = hide_stars and (current_level + 1)
          or ((current_level - 1) * shift + current_level + 1)
        if pad_size > 0 then
          frame_map[row] = string.rep(" ", pad_size)
        end
      end
    end
  end
end

-- Indent uses a buf-attach / persistent-extmark design rather than the
-- decoration provider's on_win + on_line + ephemeral pattern.  The
-- decoration model was visually unreliable in some user setups
-- (something downstream of the per-row dispatcher clear was preventing
-- ephemeral inline virt_text from rendering, even when the marks were
-- demonstrably being placed).  Persistent marks via nvim_buf_set_extmark
-- aren't subject to that race: once placed, they stay on the buffer
-- and render on every redraw until the next refresh.  Cost: a full
-- refresh on every buffer edit, but org files are small enough and
-- tree-sitter is incremental, so this is cheap in practice.

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
    })
  end
end

-- Schedule a refresh: defer to the end of the current event tick so a
-- burst of on_lines from a single edit collapses to one refresh, and
-- so a full re-walk on a large buffer (place_marks is O(buffer size))
-- doesn't block the user's keystroke.
local _scheduled = {}
local function schedule_refresh(bufnr)
  if _scheduled[bufnr] then
    return
  end
  _scheduled[bufnr] = true
  vim.schedule(function()
    _scheduled[bufnr] = nil
    place_marks(bufnr)
  end)
end

-- Public entry point: still called `refresh` for back-compat with the
-- test surface and any user that drove it manually.  Synchronous so
-- tests can inspect extmarks immediately after the call.
function M.refresh(bufnr)
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
  -- Subscribe to buffer edits.  Returning true from on_lines detaches.
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, b, _changedtick, first, _last_old, last_new)
      if not M._attached[b] then
        return true
      end
      -- A heading row was touched (promote / demote / typing a leading
      -- `*`): refresh synchronously so the new pads land before nvim's
      -- next redraw.  Otherwise the deferred schedule would paint one
      -- frame with stale pad WIDTHS while the line text is already at
      -- its new level -- visible as a one-frame flush-left flash on
      -- subtree promote / demote.
      --
      -- Body-only edits (typing in prose) cannot change anyone's pad,
      -- so they stay on the scheduled path: the per-keystroke cost
      -- stays at "queue one callback", not "walk the whole buffer".
      local heading_touched = false
      for r = first, last_new - 1 do
        local txt = vim.api.nvim_buf_get_lines(b, r, r + 1, false)[1] or ""
        if txt:sub(1, 1) == "*" then
          heading_touched = true
          break
        end
      end
      if heading_touched then
        pcall(place_marks, b)
      else
        schedule_refresh(b)
      end
    end,
    on_detach = function(_, b)
      M._attached[b] = nil
    end,
  })
  M.refresh(bufnr)
end

function M.detach(bufnr)
  if not M._attached[bufnr] then
    return
  end
  M._attached[bufnr] = nil
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
