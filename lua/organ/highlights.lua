-- Default highlight-group registration for organ.nvim tree-sitter captures.

local M = {}

-- Heading-per-level highlight links.  Linking (rather than hard-
-- coding hex) lets every colorscheme drive the palette.
--
-- Progressive enhancement: TRY `@markup.heading.N.markdown` first —
-- modern colorschemes that ship markdown coverage (catppuccin,
-- tokyonight, gruvbox-material, kanagawa, etc.) tune those groups
-- per-level for outline hierarchy.  When a level isn't styled
-- (default colorscheme, minimalist themes), FALL BACK to a core vim
-- highlight group every colorscheme defines so the heading still
-- renders distinctly.  The actual link picked is computed lazily in
-- `register()` based on what's defined when the user's colorscheme
-- has loaded.
--
-- Order tracks Emacs's `org-level-N` defaults: emphasised headings
-- at the top, progressively lower-key as depth increases.
--
-- Users can override per-level by setting their own highlight group:
--   vim.api.nvim_set_hl(0, "@org.heading.1", { fg = "#hex", bold = true })
local LEVEL_PRIMARY = {
  [1] = "@markup.heading.1.markdown",
  [2] = "@markup.heading.2.markdown",
  [3] = "@markup.heading.3.markdown",
  [4] = "@markup.heading.4.markdown",
  [5] = "@markup.heading.5.markdown",
  [6] = "@markup.heading.6.markdown",
  [7] = "@markup.heading.6.markdown", -- markdown caps at 6
  [8] = "@markup.heading.6.markdown",
}
local LEVEL_FALLBACK = {
  [1] = "Title",
  [2] = "Function",
  [3] = "Statement",
  [4] = "Type",
  [5] = "Identifier",
  [6] = "Constant",
  [7] = "Special",
  [8] = "PreProc",
}

-- True when the named highlight group has any visible attribute
-- (fg/bg/sp/bold/...) OR resolves through a link chain to one.
-- Returns false for empty groups (`vim.empty_dict`) so we know to
-- pick a fallback.
local function hl_is_styled(name)
  -- link = false resolves the link chain and returns effective attributes;
  -- the default (link = true) returns the link pointer instead.  Styled if
  -- it resolves to any attribute, or is a link at all (a link to a group not
  -- yet loaded still signals intent to style).
  local effective = vim.api.nvim_get_hl(0, { name = name, link = false })
  if next(effective) ~= nil then
    return true
  end
  local as_link = vim.api.nvim_get_hl(0, { name = name })
  return next(as_link) ~= nil
end

-- TODO keyword colors follow org state semantics mapped onto the theme's
-- diagnostic groups (which every colorscheme tunes to look good):
--   actionable (TODO / NEXT / ...)       -> DiagnosticError  red    "do it"
--   blocked    (WAITING / HOLD / ...)    -> DiagnosticWarn   yellow "waiting on"
--   done       (DONE / ...)              -> DiagnosticOk     green  "accomplished"
--   cancelled  (CANCELLED / CLOSED /...) -> Comment          grey   "abandoned"
-- Distinction from a same-hue heading comes structurally from the pill
-- badge (modern.pills), not the hue -- so no heading-collision hue swapping
-- (which produced arbitrary, ugly colors) is needed.  Each bucket resolves
-- to the first styled group in its chain, so themes lacking the newer
-- Diagnostic* groups still get a sensible color.
local BUCKET_CHAINS = {
  actionable = { "DiagnosticError", "Error", "ErrorMsg" },
  blocked = { "DiagnosticWarn", "WarningMsg" },
  done = { "DiagnosticOk", "@diff.plus", "DiffAdd", "Added", "String" },
  cancelled = { "Comment", "NonText" },
}
-- Name heuristics inside the active / done split (case-insensitive).
local BLOCKED_NAMES = {
  WAITING = true,
  WAIT = true,
  HOLD = true,
  BLOCKED = true,
  SOMEDAY = true,
  DEFERRED = true,
  PENDING = true,
}
local CANCELLED_NAMES = {
  CANCELLED = true,
  CANCELED = true,
  CLOSED = true,
  ABANDONED = true,
  WONTFIX = true,
  WONT = true,
}

-- Keyword (+ whether it sits after `|` in its sequence) -> semantic bucket.
local function todo_bucket(keyword, is_done)
  local u = keyword:upper()
  if is_done then
    return CANCELLED_NAMES[u] and "cancelled" or "done"
  end
  return BLOCKED_NAMES[u] and "blocked" or "actionable"
end

-- First styled group in a bucket's fallback chain (chain head as last resort).
local function bucket_link(bucket)
  local chain = BUCKET_CHAINS[bucket] or BUCKET_CHAINS.actionable
  for _, g in ipairs(chain) do
    if hl_is_styled(g) then
      return g
    end
  end
  return chain[1]
end

-- Shared with organ.modern.pills so the badge color matches the text color.
M.todo_bucket = todo_bucket
M.todo_bucket_link = bucket_link

-- Link @org.todo.<kw> to its semantic bucket color (bold).
local function set_todo_keyword_hl(keyword, is_done)
  vim.api.nvim_set_hl(0, "@org.todo." .. keyword:lower(), {
    link = bucket_link(todo_bucket(keyword, is_done)),
    default = true,
    bold = true,
  })
end

-- Effective foreground (24-bit int) of `name`, following any link chain;
-- nil when it has no fg.  `link = false` is REQUIRED: nvim_get_hl defaults
-- to link = true, which returns the link pointer ({ link = "X" }, no fg)
-- for a linked group.  Exposed so organ.modern.pills can build a badge
-- background from the same color the keyword text uses.
local function resolved_fg(name)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  return (ok and hl) and hl.fg or nil
end
M.resolved_fg = resolved_fg

local STATIC_LINKS = {
  ["@org.priority"] = "Special",
  ["@org.tag"] = "Identifier",
  -- `#+TITLE: …` / `#+CATEGORY: …` / `#+OPTIONS: …` / etc.  The
  -- whole line + each field decomposition.  Defaults match Emacs's
  -- "directive" face: the `#+name:` part sits in PreProc/Comment-ish
  -- territory while the value reads as String so it stands out from
  -- the directive label.
  ["@org.keyword"] = "Comment",
  ["@org.keyword.name"] = "PreProc",
  ["@org.keyword.value"] = "String",
  ["@org.keyword.affiliated"] = "Comment",
  -- #+TITLE: — Emacs gives the document title its own `org-document-
  -- title` face (same family as level-1 headings).  Linked to the
  -- same group as @org.heading.1 (computed in register() via
  -- progressive enhancement).
  -- List bullets + checkbox states — distinct color from list body
  -- so eyes can quickly scan the structure (Emacs renders these in
  -- `org-list-dt` / `org-checkbox` faces).
  ["@org.list.bullet"] = "Special",
  ["@org.list.checkbox"] = "Constant",
  -- Description-list term + `::` separator (`- term :: definition`).
  -- Emacs uses `org-list-dt` for the term and a distinct face for
  -- the separator.  We give the term a Type-ish accent so it reads
  -- as a label and the separator a softer Comment color so it
  -- doesn't compete with the term.
  ["@org.list.term"] = "Type",
  ["@org.list.term_separator"] = "Operator",
  -- Headline title text (per-level via @org.heading.title.N — set
  -- with a per-level color in `register()` below).
  ["@org.planning.scheduled"] = "Function",
  ["@org.planning.deadline"] = "WarningMsg",
  ["@org.planning.closed"] = "Comment",
  -- Bare `SCHEDULED:` / `DEADLINE:` / `CLOSED:` keyword token
  -- (without specific scheduled/deadline classification).  Used by
  -- the highlight query that captures the planning-keyword token
  -- node directly.
  ["@org.planning.keyword"] = "Statement",
  -- Statistics cookies in headings: `[3/5]`, `[60%]`.  Emacs uses
  -- a distinct `org-todo-stats` face so progress reads at a glance.
  ["@org.statistics"] = "Special",
  ["@org.cookie"] = "Special",
  -- Block bodies (#+begin_X / #+end_X frame).  Linked to a non-
  -- aggressive group so the whole block reads as a unit but
  -- doesn't drown out the document body.  Per-flavour overrides
  -- below for src / example / quote / verse / export.
  ["@org.block"] = "NonText",
  ["@org.block.src"] = "Normal",
  ["@org.block.example"] = "Comment",
  ["@org.block.quote"] = "Special",
  ["@org.block.verse"] = "String",
  ["@org.block.export"] = "Comment",
  ["@org.block.center"] = "Normal",
  ["@org.block.dynamic"] = "PreProc",
  ["@org.block.comment"] = "Comment",
  ["@org.block.language"] = "Type",
  ["@org.block.header_args"] = "Constant",
  ["@org.timestamp"] = "Number",
  ["@org.timestamp.date"] = "Number",
  ["@org.timestamp.time"] = "Number",
  ["@org.timestamp.dayname"] = "Constant",
  ["@org.timestamp.repeater"] = "Special",
  ["@org.timestamp.repeater.alarm"] = "WarningMsg",
  ["@org.timestamp.repeater.filter"] = "PreProc",
  ["@org.timestamp.warning"] = "WarningMsg",
  ["@org.timestamp.diary"] = "Special",
  ["@org.timestamp.range"] = "Number",
  ["@org.citation"] = "Function",
  ["@org.citation.style"] = "Special",
  ["@org.citation.key"] = "Identifier",
  ["@org.citation.prefix"] = "String",
  ["@org.citation.suffix"] = "String",
  ["@org.drawer.marker"] = "Comment",
  ["@org.link.target"] = "Underlined",
  ["@org.link.description"] = "Underlined",
  ["@org.drawer"] = "Comment", -- fallback when literal-token captures fail
  ["@org.link.bracket"] = "Underlined", -- fallback for whole-link capture
  -- Tables: every table element (cells, rows, the |---| rule line) uses
  -- ONE shared accent group so the whole table reads as a unit. Linking
  -- to `Number` (a soft accent in most colorschemes — peach in catppuccin,
  -- orange in tokyonight, etc.) makes the table visually distinct from
  -- prose without italic/bold noise. The rule line gets the SAME color as
  -- cells — we don't fade it; it's part of the table.
  ["@org.table"] = "Number",
  ["@org.table.row"] = "Number",
  ["@org.table.delimiter"] = "Number",
  -- Habit consistency-graph glyph colors (used by `lua/organ/habit.lua`).
  ["OrgHabitDone"] = "DiffAdd", -- on-time completion
  ["OrgHabitAhead"] = "Function", -- completed before due
  ["OrgHabitLate"] = "WarningMsg", -- completed after due
  ["OrgHabitClear"] = "Comment", -- no completion, within window
  ["OrgHabitOverdue"] = "Error", -- past alarm window
  -- Snacks/telescope/fzf-lua picker columns. We reuse the agenda's
  -- per-keyword/per-priority groups for todo/priority/tag (so a single
  -- color override there propagates everywhere); the find-specific
  -- groups below are for the columns the agenda doesn't render.
  ["@organ.find.title"] = "Normal",
  ["@organ.find.path"] = "Comment",
  ["@organ.find.backlinks"] = "Special",
  ["@organ.radio"] = "Underlined",
}

-- Default per-keyword links for the common TODO keywords. Without these,
-- a heading like `*** NEXT Read ...` gets the @org.todo.next capture
-- (rewritten by the #org-todo-keyword! directive) which has no link
-- registered, leaving the keyword bytes uncolored AND suppressing the
-- @org.heading.N color for those bytes. register_todo_keywords below
-- replaces this with the user's actual sequence once setup() runs.
local DEFAULT_TODO_KEYWORDS = {
  active = { "TODO", "NEXT", "WAITING", "HOLD", "PROJ", "STARTED", "WAIT" },
  done = { "DONE", "CANCELLED", "CANCELED", "CLOSED" },
}

function M.register()
  for grp, link in pairs(STATIC_LINKS) do
    vim.api.nvim_set_hl(0, grp, { link = link, default = true })
  end
  local title_link
  for level = 1, 8 do
    -- Progressive enhancement: prefer the markdown markup group
    -- when the user's colorscheme styles it; otherwise fall back to
    -- the always-defined core vim group.
    local primary = LEVEL_PRIMARY[level]
    local fallback = LEVEL_FALLBACK[level]
    local link = hl_is_styled(primary) and primary or fallback
    if level == 1 then
      title_link = link
    end
    vim.api.nvim_set_hl(0, "@org.heading." .. level, { link = link, default = true })
    vim.api.nvim_set_hl(0, "@org.heading.title." .. level, { link = link, default = true })
  end
  -- #+TITLE: shares the same link as level-1 headings via the same
  -- progressive-enhancement chain.
  vim.api.nvim_set_hl(0, "@org.keyword.title", { link = title_link or "Title", default = true })

  -- Inline markup faces: explicit bold/italic/etc. defaults so
  -- *bold*, /italic/, _underline_, +strike+ visually render with the
  -- attribute even when the user's colorscheme didn't style
  -- @markup.bold / @markup.italic itself.  `default = true` lets
  -- explicit user overrides win.
  vim.api.nvim_set_hl(0, "@markup.bold", { bold = true, default = true })
  vim.api.nvim_set_hl(0, "@markup.italic", { italic = true, default = true })
  vim.api.nvim_set_hl(0, "@markup.underline", { underline = true, default = true })

  -- Folded lines in org buffers should blend with the buffer
  -- background instead of vim's default grey ribbon -- the heading
  -- under the cursor reads the same folded as it does unfolded
  -- (Emacs `org-fold` look).  Defined as `bg = "NONE"` so each
  -- segment's foreground (TODO, title, tags) renders on top of
  -- Normal's background.  Activated via `winhighlight` in
  -- ftplugin/core.lua, scoped to org windows only.
  vim.api.nvim_set_hl(0, "OrgFolded", { bg = "NONE", default = true })
  vim.api.nvim_set_hl(0, "@markup.strikethrough", { strikethrough = true, default = true })
  -- Catch-all groups for the per-keyword query directives in
  -- queries/org/highlights.scm. Per-keyword groups are also registered in
  -- register_todo_keywords below; these defaults make sure colors show up
  -- even when the user hasn't called setup() yet.

  vim.api.nvim_set_hl(
    0,
    "@org.todo.active",
    { link = bucket_link("actionable"), default = true, bold = true }
  )
  vim.api.nvim_set_hl(
    0,
    "@org.todo.done",
    { link = bucket_link("done"), default = true, bold = true }
  )
  for _, kw in ipairs(DEFAULT_TODO_KEYWORDS.active) do
    set_todo_keyword_hl(kw, false)
  end
  for _, kw in ipairs(DEFAULT_TODO_KEYWORDS.done) do
    set_todo_keyword_hl(kw, true)
  end
end

-- Register per-keyword TODO groups derived from config.todo.sequence.
-- Each keyword links to its semantic bucket color (|organ-config-todo|):
-- actionable/blocked before `|`, done/cancelled after.
function M.register_todo_keywords(sequence_or_sequences)
  local sequences = require("organ.todo")._normalise_sequences(sequence_or_sequences or {})
  for _, seq in ipairs(sequences) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      else
        set_todo_keyword_hl(k, in_done)
      end
    end
  end
end

-- Scan a buffer for `#+TODO:` directives and register `@org.todo.<kw>`
-- highlight groups for each keyword found.  Called from FileType=org
-- so per-file todo states (`WAIT`, `SOMEDAY`, etc. introduced inline)
-- get the right active/done coloring without a global config change.
-- Idempotent — re-registering with `default = true` won't stomp user
-- overrides.
function M.register_buffer_todo_keywords(bufnr)
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local n = math.min(200, vim.api.nvim_buf_line_count(bufnr))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
  for _, l in ipairs(lines) do
    local val = l:match("^%s*#%+[Tt][Oo][Dd][Oo]:%s*(.*)$")
    if val then
      local seq = {}
      for tok in val:gmatch("%S+") do
        if tok == "|" then
          seq[#seq + 1] = "|"
        else
          local kw = tok:match("^([%w_%-]+)") or tok
          if kw ~= "" then
            seq[#seq + 1] = kw
          end
        end
      end
      M.register_todo_keywords(seq)
    end
  end
end

-- Treesitter-capture highlight group for a heading title at `level`.
-- Mirrors the per-level `@org.heading.title.N` captures the highlights
-- query emits (levels > 8 fall back to the unnumbered group).  Shared by
-- the foldtext renderer and the modern-bullet glyph so a heading's title,
-- its folded ellipsis, and its bullet all render in one color.
function M.heading_title_hl(level)
  if level and level >= 1 and level <= 8 then
    return "@org.heading.title." .. level .. ".org"
  end
  return "@org.heading.title.org"
end

return M
