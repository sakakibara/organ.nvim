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
  -- nvim_get_hl resolves links by default; pass link = false to see
  -- the raw definition first.  Use both to detect both an explicit
  -- definition AND a working link.
  local raw = vim.api.nvim_get_hl(0, { name = name, link = false })
  if next(raw) ~= nil then
    return true
  end
  local resolved = vim.api.nvim_get_hl(0, { name = name })
  return next(resolved) ~= nil
end

local TODO_DEFAULT_ACTIVE = "WarningMsg"
local TODO_DEFAULT_DONE = "Comment"

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
    { link = TODO_DEFAULT_ACTIVE, default = true, bold = true }
  )
  vim.api.nvim_set_hl(
    0,
    "@org.todo.done",
    { link = TODO_DEFAULT_DONE, default = true, bold = true }
  )
  for _, kw in ipairs(DEFAULT_TODO_KEYWORDS.active) do
    vim.api.nvim_set_hl(
      0,
      "@org.todo." .. kw:lower(),
      { link = TODO_DEFAULT_ACTIVE, default = true, bold = true }
    )
  end
  for _, kw in ipairs(DEFAULT_TODO_KEYWORDS.done) do
    vim.api.nvim_set_hl(
      0,
      "@org.todo." .. kw:lower(),
      { link = TODO_DEFAULT_DONE, default = true, bold = true }
    )
  end
end

-- Register per-keyword TODO groups derived from config.todo.sequence.
-- Active states (before `|`) link to TODO_DEFAULT_ACTIVE; done states
-- (after `|`) link to TODO_DEFAULT_DONE.
function M.register_todo_keywords(sequence_or_sequences)
  local sequences = require("organ.todo")._normalise_sequences(sequence_or_sequences or {})
  for _, seq in ipairs(sequences) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      else
        local link = in_done and TODO_DEFAULT_DONE or TODO_DEFAULT_ACTIVE
        vim.api.nvim_set_hl(
          0,
          "@org.todo." .. k:lower(),
          { link = link, default = true, bold = true }
        )
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

return M
