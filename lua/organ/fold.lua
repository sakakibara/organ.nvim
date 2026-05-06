-- Org-style fold cycling for organ.nvim. <Tab> advances 3-state per
-- headline (folded → children → subtree). <S-Tab> cycles foldlevel
-- globally (99 → 1 → 0 → 99).

local M = {}

-- Per-buffer per-line state cache: state ∈ "folded" | "children" | "subtree"
M._state = {}

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
  while target_node and target_node:type() ~= "headline" do
    target_node = target_node:parent()
  end
  if not target_node then
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
    pcall(vim.cmd, "silent! " .. headline_line .. "," .. end_line .. "foldclose!")
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
  local heading, headline_line = find_heading_at(bufnr, line)
  if not heading then
    return
  end
  apply_state(bufnr, heading, headline_line, state)
  M._state[bufnr] = M._state[bufnr] or {}
  M._state[bufnr][headline_line] = state
end

function M.cycle(bufnr, line)
  -- Cursor on a (property_)drawer line: toggle that drawer's fold
  -- (Emacs `org-cycle` behavior on drawer headers).  Falls through
  -- to the headline cycle below for any other line.
  local drawer = find_drawer_at(bufnr, line)
  if drawer then
    local sr = drawer:start() + 1
    local saved = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { sr, 0 })
    pcall(vim.cmd, "silent! normal! za")
    pcall(vim.api.nvim_win_set_cursor, 0, saved)
    return
  end

  local heading, headline_line = find_heading_at(bufnr, line)
  if not heading then
    pcall(vim.cmd, "silent! normal! za")
    return
  end

  M._state[bufnr] = M._state[bufnr] or {}
  local cur = M._state[bufnr][headline_line] or "folded"
  local nxt = next_state(cur)
  apply_state(bufnr, heading, headline_line, nxt)
  M._state[bufnr][headline_line] = nxt
end

-- <S-Tab>: cycle the global state through SHOW_ALL -> OVERVIEW ->
-- CONTENTS -> SHOW_ALL.  Mirrors Emacs `org-shifttab`.
--
-- SHOW_ALL: everything visible (foldlevel=99, no conceal layer).
-- OVERVIEW: only top-level headings (foldlevel=0).
-- CONTENTS: every heading visible, body hidden.  Two strategies:
--   * body_fold = false (default): conceal-layer over body ranges
--     (foldlevel stays at 99; body lines are concealed via extmarks).
--   * body_fold = true: foldlevel = max_heading_depth (body sits at
--     body_level so this hides body but keeps headings visible).
function M.cycle_global(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local body_fold = ((require("organ").config.fold or {}).body_fold == true)
  local contents = require("organ.fold.contents")
  local md = M._max_heading_depth(bufnr)
  if md < 1 then
    md = 1
  end
  local lvl = vim.wo.foldlevel
  if body_fold then
    -- body_fold strategy: state encoded in foldlevel alone.
    --   0  -> CONTENTS (md)
    --   md -> SHOW_ALL (99)
    --   else -> OVERVIEW (0)
    if lvl == 0 then
      vim.wo.foldlevel = md
    elseif lvl == md then
      vim.wo.foldlevel = 99
    else
      vim.wo.foldlevel = 0
    end
  elseif contents.is_supported() then
    -- conceal strategy: state is OVERVIEW(foldlevel=0) /
    -- CONTENTS(extmarks active) / SHOW_ALL(foldlevel=99, no extmarks).
    if contents.is_active(bufnr) then
      contents.leave(bufnr)
      vim.wo.foldlevel = 99
    elseif lvl == 0 then
      vim.wo.foldlevel = 99
      contents.enter(bufnr)
    else
      vim.wo.foldlevel = 0
    end
  else
    -- conceal_lines extmark unavailable (nvim < 0.11): no way to hide
    -- body without folding it.  Use a degraded CONTENTS where only
    -- level-1 headings stay visible (foldlevel=1) -- body still has
    -- no fold of its own.
    --   99 -> 0 (OVERVIEW), 0 -> 1 (CONTENTS-degraded), else -> 99.
    if lvl == 99 then
      vim.wo.foldlevel = 0
    elseif lvl == 0 then
      vim.wo.foldlevel = 1
    else
      vim.wo.foldlevel = 99
    end
  end
  -- Drawers (PROPERTIES, LOGBOOK, etc.) are noise unless the user
  -- explicitly opens them — Emacs's `org-cycle-hide-drawers` keeps
  -- them folded across every global-cycle state.  After foldlevel
  -- changes, re-close every drawer so a transition to "show all"
  -- still hides drawer bodies.  Tab on a drawer line still opens
  -- it (cycle()'s drawer-at-cursor branch above).
  if (require("organ").config.fold or {}).close_drawers_on_open ~= false then
    -- Defer one tick: foldlevel changes the fold state on next
    -- redraw, so foldclose on this tick may run before the new
    -- level took effect.
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.close_all_drawers(bufnr)
      end
    end)
  end
end

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
  bufnr = bufnr or vim.api.nvim_get_current_buf()
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
  local body_fold = ((require("organ").config.fold or {}).body_fold == true)
  -- body_fold = false (default): body shares the heading's level — the
  -- whole subtree is one fold.  `za` on body folds the heading.
  -- CONTENTS view is provided by an extmark layer (organ.fold.contents),
  -- not by foldlevel.
  -- body_fold = true (opt-in): body sits at body_level = max_depth + 1
  -- so `:set foldlevel = max_depth` hides body but keeps headings
  -- visible.  `za` on body folds just the body.
  local body_level
  if body_fold then
    local max_depth = 0
    for _, l in ipairs(lines) do
      local stars = l:match("^(%*+)%s")
      if stars and #stars > max_depth then
        max_depth = #stars
      end
    end
    body_level = math.max(2, max_depth + 1)
  end
  local cur_level = 0
  local in_body = false
  for i = 1, nlines do
    local line = lines[i] or ""
    local stars = line:match("^(%*+)%s")
    if stars then
      cur_level = #stars
      levels[i] = ">" .. cur_level
      in_body = false
    elseif cur_level > 0 then
      if not body_fold then
        levels[i] = tostring(cur_level)
      elseif line:match("^%s*$") then
        -- Blank lines stay at cur_level so a content-less heading's
        -- separator doesn't open a phantom 1-line body fold.
        levels[i] = in_body and tostring(body_level) or tostring(cur_level)
      elseif not in_body then
        levels[i] = ">" .. body_level
        in_body = true
      else
        levels[i] = tostring(body_level)
      end
    else
      levels[i] = "0"
    end
  end
  if body_fold then
    -- Demote trailing blanks (assigned body_level above) back to cur_level.
    local section_level = 0
    local trailing_start = nil
    for i = 1, nlines do
      local line = lines[i] or ""
      local stars = line:match("^(%*+)%s")
      if stars then
        if trailing_start then
          for j = trailing_start, i - 1 do
            levels[j] = tostring(section_level)
          end
          trailing_start = nil
        end
        section_level = #stars
      elseif section_level > 0 then
        if line:match("^%s*$") then
          trailing_start = trailing_start or i
        else
          trailing_start = nil
        end
      end
    end
    if trailing_start then
      for j = trailing_start, nlines do
        levels[j] = tostring(section_level)
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
M._headline_level = headline_level
M._max_heading_depth = max_heading_depth

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

-- Renderer: heading line + an Emacs-style ellipsis suffix when the
-- fold hides real content.  Mirrors Emacs `org-ellipsis` (default
-- `…`, no leading space).  All-blank body is left bare.  Returns
-- `{text, hl_group}` segments when a treesitter parser is attached
-- so the heading keeps its TODO / title / tag colors; falls back to
-- a plain string on buffers without an active parser.  Wrapped in
-- pcall in `M.foldtext` -- any error returns the bare heading line
-- so vim never falls back to its own `+--  N lines:` default.
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
    if has_real then
      result[#result + 1] = { "…", M.heading_title_hl(line) }
    end
    return result
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
  local cfg = (require("organ").config.fold or {}).foldtext
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

-- Org-aware fold-marker for custom statuscolumns.  In org buffers,
-- only heading lines (`^%*+%s`) get a fold-start marker; body lines
-- never do (the body-level fold layer enables CONTENTS view but is
-- visual noise on the foldcolumn).  Non-org buffers fall back to
-- level-compare (`foldlevel(lnum) > foldlevel(lnum - 1)`).
function M.statuscolumn_marker(lnum, opts)
  opts = opts or {}
  local hl = opts.hl or "FoldColumn"
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
    return line:match("^%*+%s") and paint(open_ch) or " "
  end
  if vim.fn.foldlevel(lnum) > vim.fn.foldlevel(lnum - 1) then
    return paint(open_ch)
  end
  return " "
end

-- Cleanup on BufWipeout.
function M.forget(bufnr)
  M._state[bufnr] = nil
  pcall(function()
    require("organ.fold.contents").forget(bufnr)
  end)
end

return M
