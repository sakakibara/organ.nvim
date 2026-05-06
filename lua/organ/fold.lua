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

-- <S-Tab>: cycle the buffer's global foldlevel through three logical
-- states regardless of cursor position.  Mirrors Emacs `org-shifttab`
-- (which calls `org-cycle-internal-global`).  Per-drawer toggling
-- lives on `<Tab>` (cycle()).
function M.cycle_global(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Emacs `org-cycle-internal-global` cycles through three states:
  --   SHOW_ALL  -> OVERVIEW  -> CONTENTS  -> SHOW_ALL
  --
  -- foldlevel mapping:
  --   SHOW_ALL  foldlevel = 99                everything visible
  --   OVERVIEW  foldlevel = 0                 only top-level headings
  --                                           (each sits at the head
  --                                           of its level-1 fold,
  --                                           so the line is shown
  --                                           even though the fold
  --                                           is closed)
  --   CONTENTS  foldlevel = max_heading_depth every heading line
  --                                           visible, all body
  --                                           hidden (body sits at
  --                                           body_level = max+1)
  --
  -- Cycle decision: from OVERVIEW (0) → CONTENTS; from CONTENTS (md)
  -- → SHOW_ALL; otherwise → OVERVIEW.  Robust against post-`zR`
  -- starts and any non-canonical foldlevel.
  local md = M._max_heading_depth(bufnr)
  if md < 1 then
    md = 1
  end
  local lvl = vim.wo.foldlevel
  if lvl == 0 then
    vim.wo.foldlevel = md
  elseif lvl == md then
    vim.wo.foldlevel = 99
  else
    vim.wo.foldlevel = 0
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
  -- Pass 1a: scan for max heading depth in the buffer.  Used to
  -- assign body lines to a uniform `body_level = max_depth + 1` so
  -- CONTENTS (foldlevel = max_depth) hides every body line at once.
  -- Without this, body of shallow headings would be at lower fold
  -- levels and stay visible under CONTENTS.
  local max_depth = 0
  for _, l in ipairs(lines) do
    local stars = l:match("^(%*+)%s")
    if stars and #stars > max_depth then
      max_depth = #stars
    end
  end
  local body_level = math.max(2, max_depth + 1)
  -- Pass 1b: outline.  Heading at depth N starts a level-N fold;
  -- the FIRST body line under each heading explicitly opens a
  -- level-`body_level` fold (`>body_level`) so vim creates the body
  -- fold even when the body is a single line.  All body lines share
  -- `body_level` so a single foldlevel = max_depth hides every body
  -- in one stroke (Emacs's CONTENTS view).  Requires
  -- `foldminlines = 0` on the window (set in ftplugin/core.lua) so
  -- vim accepts 1-line folds.
  -- Blank lines stay at cur_level so a content-less heading's
  -- separator doesn't open a phantom 1-line body fold.
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
      if line:match("^%s*$") then
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
  -- Demote trailing blanks (assigned body_level above) back to cur_level.
  do
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
      local er = math.min(node:end_(), nlines)
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

-- Custom foldtext: "* Heading ◉ N items hidden".  When the fold
-- spans zero hidden lines (a 1-line fold whose body collapsed to
-- just whitespace), drop the suffix entirely -- 'N items hidden'
-- with N=0 reads as a confusing artifact.  When the body is only
-- whitespace, also skip -- there's nothing meaningful to summarise.
function M.foldtext()
  local lnum = vim.v.foldstart
  local line = vim.fn.getline(lnum)
  local hidden = vim.v.foldend - vim.v.foldstart
  if hidden <= 0 then
    return line
  end
  -- If every line inside the fold is blank/whitespace-only, the
  -- fold is hiding nothing useful.  Same UX rationale: drop the
  -- "N items hidden" hint that promises content where there's none.
  local all_blank = true
  for i = lnum + 1, vim.v.foldend do
    if vim.fn.getline(i):match("%S") then
      all_blank = false
      break
    end
  end
  if all_blank then
    return line
  end
  return line .. "  ◉ " .. hidden .. " items hidden"
end

-- Cleanup on BufWipeout.
function M.forget(bufnr)
  M._state[bufnr] = nil
end

return M
