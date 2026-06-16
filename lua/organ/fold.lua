-- Org-style fold cycling for organ.nvim.  Mirrors Emacs `org-cycle`
-- and `org-shifttab`:
--   <Tab>   per-headline 3-state cycle: folded -> children -> subtree.
--   <S-Tab> global cycle: SHOW_ALL -> OVERVIEW -> CONTENTS -> SHOW_ALL.
-- Names and semantics match Emacs; see cycle_global below for the
-- foldlevel / conceal-layer mapping per state.

local M = {}

-- Per-buffer per-line state cache: state ∈ "folded" | "children" | "subtree"
M._state = {}

-- `0` is vim's "current buffer" alias but truthy in Lua, so a plain
-- `b = b or vim.api.nvim_get_current_buf()` doesn't expand it -- the
-- bufnr-keyed state in this module (and in `fold/contents.lua`)
-- would desync if a caller passed `0`.  Normalize at every entry
-- point that touches `_state` or that hands `bufnr` to a sibling
-- module.
local function nbuf(b)
  if not b or b == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return b
end

local function find_heading_at(bufnr, line)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return nil, nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil, nil
  end
  local root = tree:root()
  local target_node = root:descendant_for_range(line - 1, 0, line - 1, 0)
  -- Bounded parent walk: a corrupt or in-progress treesitter tree
  -- shouldn't ever return a `:parent()` cycle, but bound the walk
  -- so a regression can't translate into a frozen UI.  200 levels
  -- is far deeper than any plausible org outline.
  for _ = 1, 200 do
    if not target_node or target_node:type() == "headline" then
      break
    end
    target_node = target_node:parent()
  end
  if not target_node or target_node:type() ~= "headline" then
    return nil, nil
  end
  local sr = target_node:start()
  return target_node, sr + 1
end

local function apply_state(bufnr, heading, headline_line, state)
  local end_row_0 = heading:end_()
  local buf_lines = vim.api.nvim_buf_line_count(bufnr)
  local end_line = math.min(end_row_0, buf_lines)
  if end_line < headline_line then
    end_line = headline_line
  end

  local saved = vim.api.nvim_win_get_cursor(0)

  if state == "folded" then
    vim.api.nvim_win_set_cursor(0, { headline_line, 0 })
    -- NO bang: `:foldclose!` in vim closes parent folds too (zC-like),
    -- so Tab on `** L2 a` would also collapse its enclosing `* L1`
    -- subtree -- visually identical to a global S-Tab and not what
    -- Emacs `org-cycle` does.  Plain `:foldclose` closes only the
    -- innermost folds inside the given range.
    pcall(vim.cmd, "silent! " .. headline_line .. "," .. end_line .. "foldclose")
  elseif state == "children" then
    vim.api.nvim_win_set_cursor(0, { headline_line, 0 })
    pcall(vim.cmd, "silent! " .. headline_line .. "," .. end_line .. "foldopen!")
    for child in heading:iter_children() do
      if child:type() == "headline" then
        local cr = child:start() + 1
        vim.api.nvim_win_set_cursor(0, { cr, 0 })
        pcall(vim.cmd, "silent! foldclose")
      end
    end
  elseif state == "subtree" then
    vim.api.nvim_win_set_cursor(0, { headline_line, 0 })
    pcall(vim.cmd, "silent! " .. headline_line .. "," .. end_line .. "foldopen!")
  end

  pcall(vim.api.nvim_win_set_cursor, 0, saved)
  -- Invalidate the visible-distance cache: foldclose / foldopen
  -- changed which lines are inside closed folds, but `changedtick`
  -- didn't bump so the cache otherwise holds stale entries until
  -- the cursor moves and changes its key.
  pcall(function()
    require("organ.fold.contents").invalidate_visible_cache(bufnr)
  end)
end

local function next_state(s)
  if s == "folded" then
    return "children"
  end
  if s == "children" then
    return "subtree"
  end
  return "folded"
end

-- Read the heading's current visual state directly from vim's fold
-- state (vs. the M._state cache, which can lie when the user did a
-- manual `zc` / `zo` / `zR` / `zM` outside our cycle, or when the
-- buffer just opened with `foldlevel = 99` -- the cache is empty but
-- the heading is fully expanded).  Matches Emacs `org-cycle`: the
-- cycle starts from what the user actually SEES.
--
--   foldclosed(headline_line) > 0 -> entire heading collapsed: FOLDED
--   any child heading folded      -> CHILDREN
--   else                          -> SUBTREE
local function detect_heading_state(heading, headline_line)
  if vim.fn.foldclosed(headline_line) > 0 then
    return "folded"
  end
  for child in heading:iter_children() do
    if child:type() == "headline" then
      local cr = child:start() + 1
      if vim.fn.foldclosed(cr) > 0 then
        return "children"
      end
    end
  end
  return "subtree"
end

-- Find the (drawer | property_drawer) node containing `line` (1-based),
-- or nil if cursor isn't inside one.
local function find_drawer_at(bufnr, line)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return nil
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end
  local target = tree:root():descendant_for_range(line - 1, 0, line - 1, 0)
  while target do
    local t = target:type()
    if t == "drawer" or t == "property_drawer" then
      return target
    end
    target = target:parent()
  end
  return nil
end

-- Set a heading's local visibility state directly: "folded",
-- "children", or "subtree".  Used by external callers (e.g. CONTENTS
-- view's `zc` / `zo` overrides) that want a specific outcome rather
-- than the next state in the cycle.  Heading is located from the
-- given line; no-op on non-heading lines.
function M.set_heading_state(bufnr, line, state)
  bufnr = nbuf(bufnr)
  local heading, headline_line = find_heading_at(bufnr, line)
  if not heading then
    return
  end
  apply_state(bufnr, heading, headline_line, state)
  M._state[bufnr] = M._state[bufnr] or {}
  M._state[bufnr][headline_line] = state
end

local function cycle_heading(bufnr, heading, headline_line)
  M._state[bufnr] = M._state[bufnr] or {}
  local cur = detect_heading_state(heading, headline_line)
  local nxt = next_state(cur)
  apply_state(bufnr, heading, headline_line, nxt)
  M._state[bufnr][headline_line] = nxt
end

-- <Tab>: 3-state cycle when on a headline, toggle when on a drawer line.
-- Returns true when an org visibility action was taken, false when the key
-- should fall through to its native <Tab>/<C-i> meaning.
--
-- On a NON-headline line the behavior follows Emacs `org-cycle-emulate-tab`
-- (`fold.cycle_emulate_tab`):
--   true  (default): emulate <Tab> -- take no fold action and return false
--                    so the keymap passes the key through.  Emacs emulates
--                    TAB as indentation; the normal-mode analog is <C-i>.
--   false:           cycle the ENCLOSING heading's subtree (Emacs `nil`).
function M.cycle(bufnr, line)
  bufnr = nbuf(bufnr)
  -- Cursor on a (property_)drawer line: toggle that drawer's fold
  -- (Emacs `org-cycle` behavior on drawer headers).
  local drawer = find_drawer_at(bufnr, line)
  if drawer then
    local sr = drawer:start() + 1
    local saved = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { sr, 0 })
    pcall(vim.cmd, "silent! normal! za")
    pcall(vim.api.nvim_win_set_cursor, 0, saved)
    return true
  end

  -- `find_heading_at` returns the nearest enclosing headline; on a body
  -- line that headline starts ABOVE the cursor (headline_line < line), so
  -- `headline_line == line` is exactly "cursor sits on the headline".
  local heading, headline_line = find_heading_at(bufnr, line)
  if heading and headline_line == line then
    cycle_heading(bufnr, heading, headline_line)
    return true
  end

  local emulate = require("organ.buf_config").read(bufnr, "fold.cycle_emulate_tab")
  if emulate == nil then
    emulate = true
  end
  if emulate or not heading then
    return false
  end
  cycle_heading(bufnr, heading, headline_line)
  return true
end

-- Global fold states, in Emacs `org-cycle` terms:
--
--   SHOW_ALL        every line visible; drawers stay folded
--                   (`org-cycle-hide-drawers`).
--   OVERVIEW        only top-level headings (foldlevel = 0).
--   CONTENTS        every heading visible, body hidden via the
--                   `conceal_lines` extmark layer
--                   (organ.fold.contents).
--   SHOW_EVERYTHING every line visible; drawers open too.  Startup
--                   directive only (`#+STARTUP: showeverything`);
--                   not on the <S-Tab> cycle.
--
-- One applier per state, used by BOTH <S-Tab> (cycle_global, below)
-- and the `#+STARTUP:` path (ftplugin/core).  Routing both call sites
-- through the same helper is what keeps them from drifting:
-- previously the startup path inlined `foldlevel = 1` for overview,
-- which disagreed with cycle_global's `foldlevel = 0` and surfaced as
-- "the file opens showing more than overview is supposed to show".
--
-- Each applier takes explicit (winid, bufnr) so the caller doesn't
-- have to depend on whichever window happens to be current.
local function _set_local_foldlevel(winid, lvl)
  pcall(vim.api.nvim_set_option_value, "foldlevel", lvl, { win = winid, scope = "local" })
end

local function _leave_contents_if_active(winid)
  local ok, contents = pcall(require, "organ.fold.contents")
  if ok and contents.is_active and contents.is_active(winid) then
    contents.leave(winid)
  end
end

-- Drawers (PROPERTIES, LOGBOOK, etc.) are noise unless the user
-- explicitly opens them — Emacs's `org-cycle-hide-drawers` keeps
-- them folded across every global-cycle state.  After a foldlevel
-- change, re-close every drawer so a transition to "show all" still
-- hides drawer bodies.  Tab on a drawer line still opens it
-- (cycle()'s drawer-at-cursor branch handles that explicitly).
--
-- Debounce against rapid global-state changes (S-Tab spam): each
-- call would otherwise schedule a `close_all_drawers` walk that is
-- O(N tree nodes) and triggers a redraw per drawer.  Tagging each
-- call with a fresh token and short-circuiting earlier schedules
-- drops all but the final one.
local function _schedule_drawer_close(bufnr)
  if (require("organ.buf_config").read(nil, "fold") or {}).close_drawers_on_open == false then
    return
  end
  local tok = {}
  M._drawer_close_tok[bufnr] = tok
  vim.schedule(function()
    if M._drawer_close_tok[bufnr] ~= tok then
      return
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      M.close_all_drawers(bufnr)
    end
  end)
end

-- foldlevel / extmark state changed -- the visible-distance cache is
-- stale until something else (cursor move, edit) bumps its key.
-- Invalidate so statuscolumn relnum re-renders without the user
-- nudging the cursor.
local function _invalidate_visible_cache(bufnr)
  pcall(function()
    require("organ.fold.contents").invalidate_visible_cache(bufnr)
  end)
end

function M.apply_overview(winid, bufnr)
  _leave_contents_if_active(winid)
  _set_local_foldlevel(winid, 0)
  _schedule_drawer_close(bufnr)
  _invalidate_visible_cache(bufnr)
end

function M.apply_content(winid, bufnr)
  _set_local_foldlevel(winid, 99)
  require("organ.fold.contents").enter(winid)
  _schedule_drawer_close(bufnr)
  _invalidate_visible_cache(bufnr)
end

function M.apply_show_all(winid, bufnr)
  _leave_contents_if_active(winid)
  _set_local_foldlevel(winid, 99)
  _schedule_drawer_close(bufnr)
  _invalidate_visible_cache(bufnr)
end

function M.apply_show_everything(winid, bufnr)
  _leave_contents_if_active(winid)
  -- zR sets foldlevel to the highest fold level present AND opens
  -- every closed fold, including drawer folds.  That matches the
  -- `showeverything` semantic (drawers open, unlike `showall`).
  vim.api.nvim_win_call(winid, function()
    vim.cmd("silent! normal! zR")
  end)
  _invalidate_visible_cache(bufnr)
end

-- Detect the current global state of a window so cycle_global can
-- compute the next one without inlining the inverse of every
-- applier.
function M.detect_global_state(winid, bufnr)
  local ok, contents = pcall(require, "organ.fold.contents")
  if ok and contents.is_active and contents.is_active(winid) then
    return "content"
  end
  local lvl = vim.api.nvim_get_option_value("foldlevel", { win = winid })
  if lvl == 0 then
    return "overview"
  end
  return "show_all"
end

-- <S-Tab>: show_all -> overview -> content -> show_all.  Mirrors
-- Emacs `org-shifttab` / `org-cycle-global`.  `show_everything` is
-- intentionally NOT on this cycle (startup-directive only); cycling
-- through it would expose drawers and disagree with Emacs.
local _NEXT_GLOBAL = {
  show_all = "overview",
  overview = "content",
  content = "show_all",
}

function M.next_global_state(state)
  return _NEXT_GLOBAL[state] or "overview"
end

local _APPLIERS = {
  overview = function(w, b)
    M.apply_overview(w, b)
  end,
  content = function(w, b)
    M.apply_content(w, b)
  end,
  show_all = function(w, b)
    M.apply_show_all(w, b)
  end,
  show_everything = function(w, b)
    M.apply_show_everything(w, b)
  end,
}

function M.apply_global_state(state, winid, bufnr)
  local fn = _APPLIERS[state]
  if fn then
    fn(winid, bufnr)
  end
end

function M.cycle_global(bufnr)
  bufnr = nbuf(bufnr)
  -- Per-window state: two splits showing the same buffer cycle
  -- independently (S-Tab in window A doesn't move window B).
  local winid = vim.api.nvim_get_current_win()
  local next_state = M.next_global_state(M.detect_global_state(winid, bufnr))
  M.apply_global_state(next_state, winid, bufnr)
end

-- Per-buffer "latest scheduled close_all_drawers" token; see the
-- coalescing comment in `cycle_global`.
M._drawer_close_tok = {}

-- Close every drawer fold in the buffer. Called from BufReadPost on
-- org files so drawers start collapsed (matches Emacs default —
-- drawers are noise unless you opened them deliberately).
--
-- Uses cursor-position `zc` (close innermost open fold at cursor)
-- instead of `:N,M foldclose` because the latter walks up to a
-- parent fold when the range is already inside a closed fold —
-- which silently collapses the parent heading instead of the
-- drawer.  Skipping drawers whose start line is inside a closed
-- fold keeps the operation idempotent across foldlevel changes.
function M.close_all_drawers(bufnr)
  bufnr = nbuf(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return
  end
  local tree = parser:parse()[1]
  if not tree then
    return
  end
  local saved = vim.api.nvim_win_get_cursor(0)
  local last_line = vim.api.nvim_buf_line_count(bufnr)
  local function walk(node)
    local t = node:type()
    if t == "drawer" or t == "property_drawer" then
      local sr = node:start() + 1
      -- TS-tree row may point past the current buffer's last line
      -- when the buffer was mutated (e.g. refile moved a subtree
      -- out) before the parser could re-run.  Skip stale ranges.
      if sr >= 1 and sr <= last_line and vim.fn.foldclosed(sr) == -1 then
        pcall(vim.api.nvim_win_set_cursor, 0, { sr, 0 })
        pcall(vim.cmd, "silent! normal! zc")
      end
    end
    for c in node:iter_children() do
      walk(c)
    end
  end
  walk(tree:root())
  pcall(vim.api.nvim_win_set_cursor, 0, saved)
  pcall(function()
    require("organ.fold.contents").invalidate_visible_cache(bufnr)
  end)
end

-- Headline depth (count of leading `*` chars) for line `lnum` in
-- the given buffer.  Returns 0 for non-headline lines.
local function headline_level(bufnr, lnum)
  local line = (vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false) or {})[1]
  if not line then
    return 0
  end
  local stars = line:match("^(%*+)%s")
  return stars and #stars or 0
end

-- Deepest headline depth in the buffer.  Used by cycle_global to
-- pick the foldlevel for Emacs's CONTENTS state (foldlevel = max
-- heading depth keeps every heading visible while folding bodies).
local function max_heading_depth(bufnr)
  local n = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  local deepest = 0
  for _, l in ipairs(lines) do
    local stars = l:match("^(%*+)%s")
    if stars and #stars > deepest then
      deepest = #stars
    end
  end
  return deepest
end

-- Lua foldexpr for org buffers.  Two-pass:
--   1. Headline depth (counted from leading `*`) drives the outline
--      fold tree.  This is the right metric for the outline — the
--      grammar's recursively-nested `headline` node would otherwise
--      yield AST-depth folds that disagree with `*` count when lists
--      / blocks live in section bodies.
--   2. Tree-sitter walks `drawer / property_drawer / src_block / ...`
--      ranges and bumps their fold level by one over the surrounding
--      heading, so drawers and blocks get their own sub-folds.  Lists
--      are deliberately excluded: they're body content, not outline
--      structure, and giving them folds breaks heading-fold ranges.
--
-- Output format (per `:h fold-expr`):
--   ">N"   start a fold of level N at this line
--   N      this line is inside a fold of level N
--
-- Cached per-(bufnr, changedtick) so a buffer-wide refold (zX) only
-- pays the scan once.
local _foldcache = {} -- bufnr → { tick = N, levels = { lnum → "...string..." } }

-- Tree-sitter node types that should produce their own fold range,
-- nested one level deeper than the surrounding heading.  Mirrors
-- queries/org/folds.scm minus `headline` (handled by the depth pass)
-- and `inlinetask` (which has its own outline-style depth).
local FOLDABLE_NODES = {
  drawer = true,
  property_drawer = true,
  src_block = true,
  example_block = true,
  verse_block = true,
  export_block = true,
  comment_block = true,
  greater_block = true,
  dynamic_block = true,
  latex_environment = true,
  footnote_definition = true,
}

local function build_fold_levels(bufnr)
  local nlines = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, nlines, false)
  local levels = {}
  -- Body shares the parent heading's foldlevel, so the whole subtree
  -- is one fold.  CONTENTS view is provided by an extmark layer
  -- (organ.fold.contents), not by foldlevel.
  local cur_level = 0
  for i = 1, nlines do
    local line = lines[i] or ""
    local stars = line:match("^(%*+)%s")
    if stars then
      cur_level = #stars
      levels[i] = ">" .. cur_level
    elseif cur_level > 0 then
      levels[i] = tostring(cur_level)
    else
      levels[i] = "0"
    end
  end
  -- cycle-separator-lines: keep the LAST N trailing blank lines of each
  -- section visible after the section folds (Emacs `org-cycle-separator-
  -- lines`).  N from config (default 2; 0 means "always 1 visible";
  -- false disables and folds every trailing blank with the section).
  -- Visible count = min(total_trailing_blanks, max(N, 1)).  The visible
  -- blanks are the ONES CLOSEST TO THE NEXT HEADING -- they get an
  -- outer foldlevel (min of the two surrounding heading levels minus 1,
  -- clamped to >= 0; or 0 at EOF) so they sit outside the section's
  -- fold range.
  local cfg_fold = require("organ.buf_config").read(nil, "fold") or {}
  local sep_n = cfg_fold.cycle_separator_lines
  if sep_n ~= false then
    sep_n = sep_n or 2
    local visible_count = math.max(sep_n, 1)
    local section_level = 0
    local trailing_start = nil
    for i = 1, nlines do
      local line = lines[i] or ""
      local stars = line:match("^(%*+)%s")
      if stars then
        -- Demote trailing blanks only when the next heading is a
        -- sibling or shallower (`#stars <= section_level`).  When
        -- going DEEPER (parent -> child), the blank is intra-parent
        -- body, not an inter-subtree separator -- demoting it would
        -- punch a hole in the parent's fold, truncating the parent's
        -- fold range to the heading line alone.
        if trailing_start and section_level > 0 and #stars <= section_level then
          local total_blanks = i - trailing_start
          local n_visible = math.min(total_blanks, visible_count)
          local outer = math.max(0, math.min(section_level, #stars) - 1)
          for j = i - n_visible, i - 1 do
            levels[j] = tostring(outer)
          end
        end
        trailing_start = nil
        section_level = #stars
      elseif section_level > 0 then
        if line:match("^%s*$") then
          trailing_start = trailing_start or i
        else
          trailing_start = nil
        end
      end
    end
    if trailing_start and section_level > 0 then
      local total_blanks = nlines - trailing_start + 1
      local n_visible = math.min(total_blanks, visible_count)
      for j = nlines - n_visible + 1, nlines do
        levels[j] = "0"
      end
    end
  end
  -- Pass 2: drawer / block sub-folds via tree-sitter.  Each foldable
  -- range bumps its fold level by 1 over the surrounding context.
  -- DFS order ensures nested foldables (e.g. a drawer inside a block)
  -- bump from the already-bumped outer level.
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return levels
  end
  local tree = (parser:parse() or {})[1]
  if not tree then
    return levels
  end
  local function level_at(idx)
    local s = levels[idx] or "0"
    return tonumber(s:match("^>?(%d+)$")) or 0
  end
  local function walk(node)
    if FOLDABLE_NODES[node:type()] then
      local sr = node:start() + 1
      -- Treesitter end is exclusive: bump by 1 when end_col > 0,
      -- else the closing marker (`#+end_src`, `:END:`) falls outside.
      local end_row, end_col = node:end_()
      local er = math.min((end_col == 0) and end_row or (end_row + 1), nlines)
      if sr >= 1 and sr <= er then
        local sub = level_at(sr) + 1
        levels[sr] = ">" .. sub
        for i = sr + 1, er do
          levels[i] = tostring(sub)
        end
      end
    end
    for c in node:iter_children() do
      walk(c)
    end
  end
  walk(tree:root())
  return levels
end

function M.foldexpr(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "org" then
    return "0"
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cache = _foldcache[bufnr]
  if not cache or cache.tick ~= tick then
    cache = { tick = tick, levels = build_fold_levels(bufnr) }
    _foldcache[bufnr] = cache
  end
  return cache.levels[lnum] or "0"
end

-- Public so a test can exercise the level assignment without going
-- through the full foldexpr eval path.
M._build_fold_levels = build_fold_levels

-- Whether the lines `foldstart+1 .. foldend` contain anything
-- non-whitespace.  Used by both renderers to drop suffix decoration
-- on folds that hide nothing meaningful.
local function fold_has_real_content(foldstart, foldend)
  for i = foldstart + 1, foldend do
    if vim.fn.getline(i):match("%S") then
      return true
    end
  end
  return false
end

-- Cache treesitter-segment results per (bufnr, lnum) keyed on
-- changedtick so a stationary fold rendering N times pays the
-- iter_captures cost once.  Cleared automatically on edit.
local _ts_seg_cache = {} -- bufnr -> { tick = N, lines = { lnum -> segments } }

-- Build {text, hl_group} segments for a single line by walking every
-- attached treesitter parser and collecting highlight captures over
-- the line range.  Later captures override earlier ones at any byte
-- (matches the highlighter's "last wins" rule), and contiguous runs
-- with the same hl are coalesced into one segment.  Returns nil if
-- no parser is attached so the caller can fall back to plain text.
--
-- Force-parses the line range across the whole language tree before
-- walking captures.  Without this, a freshly-loaded buffer (or one
-- whose injection trees haven't been parsed for this row yet -- e.g.
-- right after `<S-Tab>` flips fold state) will yield only the main
-- parser's captures and miss any injection's, producing segments
-- that later cycles can't recover from because changedtick is
-- unchanged so the seg cache returns the same partial result on
-- every call.
local function ts_line_segments_uncached(bufnr, lnum)
  local line = vim.fn.getline(lnum)
  if line == "" then
    return { { "", "Normal" } }
  end
  local row = lnum - 1
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  pcall(parser.parse, parser, { row, row + 1 })
  local hl_at = {}
  for i = 1, #line do
    hl_at[i] = nil
  end
  -- Capture priority mirrors the runtime highlighter: walk every
  -- LanguageTree in DFS order, and within each tree a lower
  -- `priority` metadata entry loses to a higher one.  Default
  -- priority is 100 (`vim.hl.priorities.treesitter`).  Tracking the
  -- winning priority per byte lets a more-specific child capture
  -- (e.g. `@org.heading.title.1`) override the broader parent
  -- capture (`@org.heading.1`) regardless of capture-iter order.
  local prio_at = {}
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local q_ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
    if not q_ok or not query then
      return
    end
    for id, node, metadata in query:iter_captures(tree:root(), bufnr, row, row + 1) do
      local capture_name = query.captures[id]
      -- Skip "private" captures (`@_foo`).  Treesitter convention
      -- treats leading-underscore names as intermediate -- they're
      -- used to bind a node to a predicate (e.g. the
      -- `((headline_line stars: (stars) @_s title: (title)
      -- @org.heading.title.1) (#org-stars-level? @_s 1))` pattern
      -- captures stars as `@_s` only to count them).  nvim's runtime
      -- highlighter skips them; we do too -- otherwise the stars on
      -- a level-1 heading get painted with the (undefined) `@_s.org`
      -- group, which renders as Normal and overrides the proper
      -- `@org.heading.1.org` capture from a parallel pattern.
      if capture_name:sub(1, 1) ~= "_" then
        local sr, sc, er, ec = node:range()
        if sr <= row and row <= er then
          local s = (sr == row) and sc or 0
          local e = (er == row) and ec or #line
          local hl = "@" .. capture_name .. "." .. lang
          local priority = tonumber((metadata[id] or {}).priority or metadata.priority) or 100
          for col = s + 1, e do
            if (prio_at[col] or -1) <= priority then
              hl_at[col] = hl
              prio_at[col] = priority
            end
          end
        end
      end
    end
  end)
  local segments = {}
  local cur_hl, run_start = hl_at[1], 1
  for col = 2, #line do
    if hl_at[col] ~= cur_hl then
      segments[#segments + 1] = { line:sub(run_start, col - 1), cur_hl or "Normal" }
      cur_hl, run_start = hl_at[col], col
    end
  end
  segments[#segments + 1] = { line:sub(run_start), cur_hl or "Normal" }
  return segments
end

local function ts_line_segments(bufnr, lnum)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = _ts_seg_cache[bufnr]
  if not entry or entry.tick ~= tick then
    entry = { tick = tick, lines = {} }
    _ts_seg_cache[bufnr] = entry
  end
  if entry.lines[lnum] == nil then
    -- nil sentinel for "no parser" results; use false to distinguish
    -- "computed and is nil" from "not yet computed".
    local segs = ts_line_segments_uncached(bufnr, lnum)
    entry.lines[lnum] = segs == nil and false or segs
  end
  local cached = entry.lines[lnum]
  if cached == false then
    return nil
  end
  return cached
end

-- Heading-title hl group for the ellipsis decoration.  Picks the
-- per-level title capture (`@org.heading.title.N.org`) when the
-- start line is a real heading; falls back to the broader heading
-- capture, then `Folded` if neither is reachable.  Used by the
-- foldtext renderer AND by `fold/contents.lua`'s virt_text suffix
-- so both visual states render the ellipsis in the same color as
-- the heading text it follows.
function M.heading_title_hl(line)
  local stars = line and line:match("^(%*+)%s")
  if not stars then
    return "Folded"
  end
  local level = #stars
  if level >= 1 and level <= 8 then
    return "@org.heading.title." .. level .. ".org"
  end
  return "@org.heading.title.org"
end

-- Resolve `config.format.headline.tags_column` into a placement
-- directive (see `organ.format._resolve_tags_column` for the full
-- contract).  Returns nil when no alignment is requested, otherwise
-- `{ kind = "flush"|"left"|"right", column = N }`.
local function resolve_tags_column_local()
  local h = (require("organ.buf_config").read(nil, "format") or {}).headline or {}
  local val = h.tags_column
  if val == nil then
    val = "textwidth"
  end
  return require("organ.format")._resolve_tags_column(val)
end

local function display_width_of_segments(segs, from, to)
  local total = 0
  for i = from, to do
    total = total + vim.fn.strdisplaywidth(segs[i][1])
  end
  return total
end

-- Renderer: heading line + an Emacs-style ellipsis suffix when the
-- fold hides real content.  Mirrors Emacs `org-ellipsis` (default
-- `…`, no leading space).  All-blank body is left bare.  Returns
-- `{text, hl_group}` segments when a treesitter parser is attached
-- so the heading keeps its TODO / title / tag colors; falls back to
-- a plain string on buffers without an active parser.  Wrapped in
-- pcall in `M.foldtext` -- any error returns the bare heading line
-- so vim never falls back to its own `+--  N lines:` default.
--
-- When the heading carries a tag_list, the ellipsis lands right
-- after the title and the tag block is right-aligned to
-- `config.format.headline.tags_column` so a folded `* TODO Foo :tag:`
-- renders as `* TODO Foo…                          :tag:` instead of
-- the tags being shoved past the ellipsis.
function M.emacs_foldtext()
  local foldstart, foldend = vim.v.foldstart, vim.v.foldend
  local has_real = foldend > foldstart and fold_has_real_content(foldstart, foldend)
  local line = vim.fn.getline(foldstart)
  local segments = ts_line_segments(vim.api.nvim_get_current_buf(), foldstart)
  if segments then
    -- Build a fresh result list every call.  Mutating the cached
    -- segments would append the ellipsis on every render, so a fold
    -- shown N times would render `* H1……………` after N redraws.
    local result = {}
    for i, seg in ipairs(segments) do
      result[i] = seg
    end
    if not has_real then
      return result
    end
    local title_hl = M.heading_title_hl(line)
    -- First segment whose hl group is in the tag capture family
    -- (`@org.tag.org` for the whole block, `@org.tag.name.org` per
    -- tag).  Whichever appears first is where the tag block starts.
    local tag_idx
    for i, seg in ipairs(result) do
      if seg[2] and seg[2]:match("^@org%.tag") then
        tag_idx = i
        break
      end
    end
    if not tag_idx then
      result[#result + 1] = { "…", title_hl }
      return result
    end
    -- Trim trailing whitespace from the segment right before the
    -- tag block so the ellipsis sits flush against the title text.
    if tag_idx > 1 then
      local prev = result[tag_idx - 1]
      local trimmed = prev[1]:match("^(.-)%s*$") or prev[1]
      result[tag_idx - 1] = { trimmed, prev[2] }
    end
    local pre_w = display_width_of_segments(result, 1, tag_idx - 1)
    local tag_w = display_width_of_segments(result, tag_idx, #result)
    local ellipsis_w = vim.fn.strdisplaywidth("…")
    local resolved = resolve_tags_column_local()
    local pad
    if resolved == nil or resolved.kind == "flush" then
      pad = 1
    elseif resolved.kind == "left" then
      pad = resolved.column - pre_w - ellipsis_w
      if pad < 1 then
        pad = 1
      end
    else
      -- "right": tag right edge at resolved.column; left edge at
      -- column - tag_w; subtract pre_w + ellipsis_w to get the pad.
      pad = (resolved.column - tag_w) - pre_w - ellipsis_w
      if pad < 1 then
        pad = 1
      end
    end
    local rebuilt = {}
    for i = 1, tag_idx - 1 do
      rebuilt[#rebuilt + 1] = result[i]
    end
    rebuilt[#rebuilt + 1] = { "…", title_hl }
    rebuilt[#rebuilt + 1] = { string.rep(" ", pad), title_hl }
    for i = tag_idx, #result do
      rebuilt[#rebuilt + 1] = result[i]
    end
    return rebuilt
  end
  if not has_real then
    return line
  end
  return line .. "…"
end

-- Dispatcher.  ftplugin/core.lua wires this as the foldtext
-- expression; the underlying renderer is selected by
-- `fold.foldtext` config.  Always returns SOMETHING renderable --
-- a top-level pcall catches any error so vim cannot silently fall
-- back to its `+--  N lines:` default (which previously surfaced
-- after multiple `<S-Tab>` cycles when a transient TS-parse error
-- propagated out of `emacs_foldtext`).
function M.foldtext()
  local cfg = (require("organ.buf_config").read(nil, "fold") or {}).foldtext
  -- `false` or `nil` -> defer to vim's builtin foldtext() (the
  -- `+--  N lines: ...` format).  Lets users opt out of organ's
  -- emacs-style decoration without having to write a custom fn.
  if cfg == false or cfg == nil then
    return vim.fn.foldtext()
  end
  if type(cfg) == "function" then
    local ok, out = pcall(cfg, vim.v.foldstart, vim.v.foldend)
    if ok and type(out) == "string" then
      return out
    end
    return vim.fn.getline(vim.v.foldstart) or ""
  end
  local ok, out = pcall(M.emacs_foldtext)
  if ok and (type(out) == "string" or type(out) == "table") then
    return out
  end
  return vim.fn.getline(vim.v.foldstart) or ""
end

-- Top-level proxies used by `fold.auto_foldtext` /
-- `fold.auto_statuscolumn` opt-in auto-apply.  Defined unconditionally
-- so the option strings can reference them without arranging
-- `require()` order at runtime.  Nvim's option-eval `v:lua` parser
-- chokes on `v:lua.require('organ.fold').foldtext()` chains in TUI
-- mode (fine in headless / `:lua`); a flat `v:lua.<name>()` is the
-- safe shape.  These proxies are dead code unless the user opts in.
_G._organ_foldtext = function()
  if vim.bo.filetype == "org" then
    return M.foldtext()
  end
  -- Buffer in this window isn't org, but our win-local 'foldtext'
  -- (set by ftplugin on the prior org buffer) is still active --
  -- window options persist across buffer changes.  Eval the
  -- buffer's effective global 'foldtext' so the user's own wrapper
  -- (or vim's builtin) handles non-org folds the same as on a
  -- window that never saw an org buffer.  Skip if the global is
  -- ALSO our proxy (would recurse).
  local global = vim.go.foldtext
  if global and global ~= "" and not global:find("_organ_foldtext", 1, true) then
    local ok, out = pcall(vim.fn.eval, global)
    if ok then
      return out
    end
  end
  return vim.fn.foldtext()
end

-- Statuscolumn eval doesn't switch curwin to the rendering window, so
-- vim.fn.foldclosed / vim.wo.* read the focused pane's state.  But the
-- redraw pipeline tells decoration providers which window is being
-- drawn (on_win fires before that window's lines), so we stash the
-- winid for `_organ_statuscolumn` to re-enter via nvim_win_call.
-- Cleared by on_end so synthetic eval paths (nvim_eval_statusline)
-- fall through to current-window behavior.
local _render_winid
local _DECO_NS = vim.api.nvim_create_namespace("organ.fold._render")
vim.api.nvim_set_decoration_provider(_DECO_NS, {
  on_win = function(_, winid)
    _render_winid = winid
    return true
  end,
  on_line = function(_, winid)
    _render_winid = winid
  end,
  on_end = function()
    _render_winid = nil
  end,
})

local function _statuscolumn_body()
  local lnum = vim.v.lnum
  local relnum = vim.v.relnum
  local virtnum = vim.v.virtnum
  if virtnum and virtnum ~= 0 then
    return "    "
  end
  -- Mirror vim's number / relativenumber semantics: number-only ->
  -- absolute everywhere, rnu-only -> 0 on cursor / distance elsewhere,
  -- hybrid -> absolute on cursor / distance elsewhere, neither -> pad.
  local nu = vim.wo.number
  local rnu = vim.wo.relativenumber
  local n_str
  if not nu and not rnu then
    n_str = "    "
  else
    local n
    if rnu and relnum and relnum ~= 0 then
      n = relnum
    elseif rnu and not nu then
      n = 0
    else
      n = lnum
    end
    n_str = string.format("%4d", n)
  end
  local fold_marker = M.statuscolumn_marker(lnum)
  -- `%s` reserves the signs column so plugins like gitsigns / lsp
  -- diagnostics keep rendering their gutter chars on org buffers
  -- even when the user opts into organ's auto-applied statuscolumn.
  return string.format("%%s%s %s ", n_str, fold_marker)
end

-- Compute the auto-applied statuscolumn output for a specific window.
-- `winid = nil` (or invalid) -> use the focused window's context.  This
-- is the testable seam: callers (and tests) can ask for a specific
-- pane's column without changing focus, and `_G._organ_statuscolumn`
-- calls it with `_render_winid` resolved from the decoration provider.
function M.statuscolumn(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_call(winid, _statuscolumn_body)
  end
  return _statuscolumn_body()
end

_G._organ_statuscolumn = function()
  return M.statuscolumn(_render_winid)
end

-- Org-aware fold-marker for custom statuscolumns.  In org buffers,
-- only heading lines (`^%*+%s`) get a fold-start marker; body lines
-- never do (the body-level fold layer enables CONTENTS view but is
-- visual noise on the foldcolumn).  Non-org buffers fall back to
-- level-compare (`foldlevel(lnum) > foldlevel(lnum - 1)`).
local function _marker_impl(lnum, hl)
  local fillchars = vim.opt.fillchars:get()
  local open_ch = fillchars.foldopen or "v"
  local close_ch = fillchars.foldclose or ">"
  local function paint(ch)
    return "%#" .. hl .. "#" .. ch .. "%*"
  end
  if vim.fn.foldlevel(lnum) == 0 then
    return " "
  end
  if vim.fn.foldclosed(lnum) > 0 then
    return paint(close_ch)
  end
  if vim.bo.filetype == "org" then
    local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
    if not line:match("^%*+%s") then
      return " "
    end
    -- CONTENTS view hides body via `conceal_lines` extmarks, not
    -- folds, so `foldclosed()` above returned -1 even when the body
    -- is visually concealed.  Ask the contents module whether THIS
    -- heading has its body concealed in CONTENTS state and reflect
    -- it as a closed-fold chevron; otherwise show open.
    local ok, contents = pcall(require, "organ.fold.contents")
    if ok and contents.heading_concealed and contents.heading_concealed(0, lnum) then
      return paint(close_ch)
    end
    return paint(open_ch)
  end
  if vim.fn.foldlevel(lnum) > vim.fn.foldlevel(lnum - 1) then
    return paint(open_ch)
  end
  return " "
end

function M.statuscolumn_marker(lnum, opts)
  opts = opts or {}
  local hl = opts.hl or "FoldColumn"
  -- vim.fn.foldclosed / foldlevel and vim.bo.filetype are window-local
  -- reads.  `opts.winid` re-enters that window via nvim_win_call so
  -- the marker reflects THAT pane's fold state, not the focused pane's.
  if opts.winid and vim.api.nvim_win_is_valid(opts.winid) then
    return vim.api.nvim_win_call(opts.winid, function()
      return _marker_impl(lnum, hl)
    end)
  end
  return _marker_impl(lnum, hl)
end

-- Cleanup on BufWipeout.
function M.forget(bufnr)
  M._state[bufnr] = nil
  pcall(function()
    require("organ.fold.contents").forget(bufnr)
  end)
end

return M
