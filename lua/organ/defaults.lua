-- lua/organ/defaults.lua
-- Canonical default configuration for organ.nvim.
--
-- Rule 5: `require("organ.defaults")` returns the canonical default config
-- tree. Users can introspect, partial-copy, or compose.
--
-- This module is pure data — no side effects, no autocmds, no requires.
-- vim.fn calls are present only because the defaults reference user paths
-- (the same calls that were previously inlined in init.lua).
--
-- ── INVARIANT ────────────────────────────────────────────────────────────
-- A field that downstream code reads as "opt-in" (i.e. behaviour only
-- triggers when the user EXPLICITLY sets the value to `true`) MUST NOT
-- have a value here. Set it nil (i.e. omit it) so `cfg.X == true` actually
-- means "user opted in". Setting `X = false` here is fine (default-off
-- with explicit-on opt-in) but `X = true` here makes "opt-in" a no-op.
--
-- The audit test `tests/defaults_opt_in_audit_test.lua` enforces this
-- against a list of known opt-in fields.

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  local dir = src:match("(.*/)") or "./"
  return dir .. "../.."
end

return {
  org_dir = vim.fn.expand("~/org"),
  -- agenda_files: which files the agenda views consider.  Combines
  -- Emacs's `org-agenda-files` shape with nvim-orgmode's glob-style.
  --
  --   nil               → no restriction; every indexed file
  --                        (default — matches our recursive org_dir).
  --   "~/org/todo.org"  → single file
  --   "~/org"           → directory; top-level `.org` /
  --                        `.org_archive` only (Emacs's
  --                        "list-with-a-directory" semantics)
  --   "~/org/**/*.org"  → glob; `*`/`?`/`[` triggers expansion via
  --                        `vim.fn.glob`. `**` matches any depth.
  --                        Matches nvim-orgmode's idiom.
  --   { "~/org/*.org",
  --     "!~/org/private/*" }
  --                     → list. Entries starting with `!` are
  --                        EXCLUSION globs applied to the union of
  --                        everything else.  Lets you say "all org
  --                        files except these" declaratively.
  --   function          → resolved at agenda-open; must return any
  --                        of the above (recursively).  Use for
  --                        arbitrary include / exclude logic that
  --                        globs can't express.
  --
  -- Per-block override: a block spec's own `files = ...` takes
  -- precedence over this top-level setting.
  agenda_files = nil,
  db_path = vim.env.ORGAN_DB_PATH or (vim.fn.stdpath("data") .. "/organ.db"),
  -- Default parser path. `lua/organ/grammar_install.lua` writes the
  -- block parser here from your plugin manager's build hook (see
  -- README). The runtime also probes nvim-treesitter's parser dir if
  -- the file isn't here. Override to point at a hand-managed binary.
  parser_path = vim.fn.stdpath("data") .. "/organ/parser/org.so",
  schema_path = plugin_root() .. "/sql/schema.sql",

  scan_on_startup = false,
  debounce_ms = 200,
  incremental = true,
  mtime_skip = true,
  hash_skip = true,
  auto_recover = true,
  -- File-write safety. write_atomic always uses tmp + fsync + rename
  -- (durable across power loss). `keep_bak` adds an extra `.bak`
  -- hardlink before the rename so the previous version of any file
  -- we write survives until the next successful write. Off by default
  -- (extra inode + cleanup); enable for paranoid setups.
  write = { keep_bak = false },
  ignore_globs = { "**/archive/**", "**/.git/**", "**/node_modules/**" },
  -- Entries the recursive directory scanner processes per vim.schedule
  -- yield while enumerating org files.
  scan_batch_size = 10,
  -- Per-slice wall-time budget for the cooperative indexer: it yields the
  -- UI after this many ms of extract work on a file, so indexing never
  -- blocks for more than ~a frame regardless of file size.
  scan_budget_ms = 10,
  row_chunk = 10000,

  notify = true,
  log_level = "info",

  pragmas = {
    journal_mode = "WAL",
    synchronous = "NORMAL",
    temp_store = "MEMORY",
    mmap_size = 268435456,
    cache_size = -64000,
    foreign_keys = "ON",
    busy_timeout = 5000,
  },

  agenda = {
    enabled = true,
    -- One-line keymap reference at the bottom of the buffer. Set false to
    -- suppress (e.g. when which-key is rendering the same info elsewhere).
    footer = true,
    -- When true, the agenda also evaluates `<%%(diary-...)>` sexps in every
    -- indexed file across each day in the visible window, and renders
    -- matching headlines as synthetic scheduled rows.
    include_diary_sexp = false,
    default_view = {
      from = "today",
      to = "+7d",
      types = { "scheduled", "deadline" },
      todo = { exclude = { "DONE", "CANCELLED" } },
      include_overdue = true,
      group_by = "day",
      order_within_group = { { "priority", "asc" }, { "todo_state", "asc" }, { "title", "asc" } },
    },
    -- Default span when a block specifies `span` instead of explicit
    -- `from`/`to` (mirror Emacs `org-agenda-span`).  Accepts:
    --   "day" | "week" | "fortnight" | "month" | "year"
    --   integer N (renders the next N days from start_day)
    -- nil → no implicit span; blocks must set `from`/`to` (or `span`)
    -- explicitly.  Per-block override via `block.span`.
    span = nil,
    -- Anchor for span resolution (mirror Emacs `org-agenda-start-day`).
    -- "today" (default), an ISO date "2026-05-04", or a relative
    -- offset "+Nd" / "-Nd".  Per-block override via `block.start_day`.
    start_day = "today",
    -- Day-of-week the weekly view aligns to when `span = "week"` /
    -- "fortnight" and `:Org agenda week`.  Mirrors Emacs
    -- `org-agenda-start-on-weekday`.  Accepted values:
    --   "monday"..."sunday"  weekday name (default "monday")
    --   "today"              no fixed anchor; window starts on the
    --                        current day (regardless of weekday)
    -- Per-block override via `block.week_starts_on`.
    week_starts_on = "monday",
    refresh_debounce_ms = 300,
    line_format = nil,
    -- Sticky agenda (Emacs `org-agenda-sticky`). When true, opening
    -- the same view twice reuses the existing buffer (preserves scroll
    -- position, fold state, bulk_marked set). Default on.
    sticky = true,
    -- Window-open strategy (mirror Emacs `org-agenda-window-setup`).
    -- Controls how :Org agenda places its buffer relative to the
    -- existing window layout:
    --   "reuse"        — replace the current window's buffer (default;
    --                    preserves layout)
    --   "only"         — close other windows, agenda fills the tab
    --   "split-below"  — horizontal split beneath the current window
    --   "vsplit-right" — vertical split to the right
    --   "tab"          — open in a new tab
    window_setup = "reuse",
    -- Restore the previous window layout on `q` close (mirror Emacs
    -- `org-agenda-restore-windows-after-quit`).  Snapshot the layout
    -- on open via `winrestcmd()`, replay it after the agenda buffer
    -- is wiped.  Default false (matches Emacs default).
    restore_windows_after_quit = false,
    -- Dispatcher UI for `:Org agenda` (no-args).
    --   "popup"   floating-window menu, blocks on getcharstr until you
    --             pick (default; works under noice / snacks / native).
    --   "echo"    nvim_echo + getcharstr (terminal-classic; gets eaten
    --             by some UI plugins so the menu fades).
    --   "select"  routes through vim.ui.select (list + enter).
    -- Or pass a custom handler via dispatcher_handler -- receives
    -- `{ title, entries = { { key, label, action }, ... } }`.
    dispatcher_style = "popup",
    dispatcher_handler = nil,
    -- Hide blocks that have zero rows from the rendered agenda
    -- (Emacs `org-agenda-hide-empty-blocks`). Default false so users
    -- see the empty-block placeholder.
    hide_empty_blocks = false,
    -- Toggle repeater expansion (Emacs `org-agenda-show-future-repeats`).
    -- Default on so daily habits show on each day in the window.
    show_future_repeats = true,
    -- Render the habit consistency graph (a string of `.`, `*`, `!`)
    -- after each habit row's tags.  Off by default because Emacs's
    -- `org-habit` ships disabled in most setups and the typical
    -- agenda view doesn't show graphs.  Set true to match an
    -- org-habit-loaded Emacs setup.
    show_habit_graphs = false,
    -- TODO-list filters (mirror Emacs `org-agenda-todo-ignore-*`).
    -- Each excludes rows from the TODO/global views (`:Org agenda todos`)
    -- when true.  Defaults match Emacs (all `nil` / off → show
    -- everything).  Per-view override via `block.todo_ignore_*`.
    --
    --   todo_ignore_scheduled  — drop rows that have a SCHEDULED
    --     timestamp (the user already sees them in the daily agenda)
    --   todo_ignore_deadlines  — drop rows that have a DEADLINE
    --   todo_ignore_with_date  — drop rows with EITHER (the union)
    todo_ignore_scheduled = false,
    todo_ignore_deadlines = false,
    todo_ignore_with_date = false,
    -- TODO-list nesting (mirror `org-agenda-todo-list-sublevels`).
    -- When `false`, only top-level (level 1) headlines appear in the
    -- TODO/global view; sub-headlines are hidden even if they carry
    -- TODO states.  Default `true` — show sublevels (Emacs default).
    todo_list_sublevels = true,
    -- Skip COMMENT trees (mirror `org-agenda-skip-comment-trees`).
    -- A headline marked `* COMMENT Foo` (the literal `COMMENT`
    -- keyword token) and all its children are excluded.  Emacs
    -- default is `true`; we match.  Use the grammar's
    -- `comment_marker` field to detect.
    skip_comment_trees = true,
    -- Format string for the TODO-state token in agenda rows
    -- (mirror `org-agenda-todo-keyword-format`).  `%s` is replaced
    -- by the keyword.  Use e.g. `"%-7s"` to right-pad to 7 chars
    -- so all rows align across `TODO` / `NEXT` / `WAITING`.
    todo_keyword_format = "%s",
    -- Render tags as a `virt_text_pos = "right_align"` extmark
    -- (default: true).  Neovim's render layer auto-positions virt-
    -- text against the right edge on every redraw, so window
    -- resizes / splits / Zen-mode toggles re-align tags for free
    -- with no buffer churn or flicker — strictly better than
    -- Emacs's "re-align on refresh only".  **Tags are guaranteed
    -- visible at the window's right edge regardless of line
    -- length or horizontal scroll** — the virt_text isn't anchored
    -- to a buffer column.
    --
    -- Set false to fall back to the inline-padding path: tag chars
    -- + alignment spaces are baked into the buffer line.  Use that
    -- when you need plain-text output (export, copy/paste, headless
    -- snapshot tests that diff line strings).  Trade-off: when
    -- a line's content is longer than `tags_column`, the tag
    -- block is appended with a 2-char gap and may extend past the
    -- visible window.  Same overflow behavior as Emacs's inline
    -- tag column.
    tags_virt_align = true,
    -- Overflow marker for rows whose title + tag block don't fit
    -- inside the visible content area.  Title visibility wins —
    -- we drop the full tag run on those rows and emit a single-cell
    -- marker (default `›`) at the right edge so users know tags
    -- exist without losing the END of a long title.  Applies to
    -- both `tags_virt_align = true` (virt_text) and the inline
    -- path.  Set `false` to keep the legacy behavior (full tags
    -- emitted; virt_text overlaps the title, inline tags clip at
    -- the window edge).
    tags_overflow_marker = "›",
    -- Inter-block separator drawn between blocks of a multi-block
    -- agenda (mirror Emacs `org-agenda-block-separator`).  Accepts:
    --   false        → no separator (just a blank line)
    --   true / nil   → default `═` glyph, repeated to the window's
    --                  content width
    --   single char  → that char repeated to width (e.g. "=", "─")
    --   longer str   → emitted verbatim, padded/clipped to width
    block_separator = true,
    -- Per-block prefix template (Emacs `org-agenda-prefix-format`).
    -- Layout for the leftmost row chunk: category, time, scheduled-
    -- prefix.  Pass a string to apply to all kinds, a table keyed by
    -- view kind for per-view defaults, or a function `(row, ctx) →
    -- string` for full control.  Set per-block via `block.prefix_format`
    -- to override.  Tokens (mirroring Emacs's mini-format-language):
    --
    --   %c           category (filename stem unless `#+CATEGORY:` set)
    --   %-Nc / %-N:c category, padded to N chars (`:` modifier appends
    --                trailing colon — Emacs's `%-12:c` form)
    --   %t           scheduled time (e.g. `9:00`)
    --   %-Nt         time, dot-padded to N chars (`9:00........`)
    --   %?-Nt        time, N spaces when empty (column stays aligned)
    --   %s / %?s     scheduling tag (`Scheduled:`, `In N d.:`, etc.)
    --
    -- nil → use organ's per-kind default table (matches Emacs's stock
    -- agenda layout).  See `:h organ-agenda-format`.
    prefix_format = nil,
    -- Roll items scheduled BEFORE the agenda window into today's
    -- bucket.  Without this, daily/weekly habits scheduled before the
    -- window (which is the common state — Emacs auto-bumps the
    -- timestamp on completion, but most habits sit there waiting)
    -- never show up until the user manually re-schedules.  Items with
    -- a repeater are projected into the window as `Sched. Nx:` rows
    -- (matching Emacs's behavior); items without a repeater appear in
    -- today's bucket too, so users see what they have to deal with.
    -- Default true; matches Emacs's effective behavior.
    show_overdue_scheduled = true,
    -- Show deadlines coming up within N days on today's bucket as
    -- `In N d.:` rows (matches Emacs `org-deadline-warning-days`,
    -- default 14). The deadline still appears on its actual day too;
    -- this is just an early-warning mention.
    deadline_warning_days = 14,
    -- Per-type "skip if DONE" filters. Finer than blanket
    -- todo.exclude — a row may be DONE on its scheduled day but
    -- still want surfacing under its deadline (or vice versa).
    -- Mirrors Emacs `org-agenda-skip-scheduled-if-done` /
    -- `org-agenda-skip-deadline-if-done`. Default false.
    skip_scheduled_if_done = false,
    skip_deadline_if_done = false,
    -- Deduplicate the day-bucket fan-out for rows that have BOTH
    -- a scheduled date AND a deadline (mirror Emacs `org-agenda-
    -- skip-scheduled-if-deadline-is-shown`).  When `true`, the row
    -- only appears on its DEADLINE day; the SCHEDULED-day entry is
    -- suppressed.  Default `false` — show both, matching Emacs's
    -- common-case where users want to see the start day AND the
    -- must-finish day.  Per-block override via
    -- `block.skip_scheduled_if_deadline_shown`.
    skip_scheduled_if_deadline_shown = false,
    -- Suppress the deadline early-warning row (`In N d.:`) on
    -- today's bucket when the row ALSO has a scheduled date in the
    -- window (mirror Emacs `org-agenda-skip-deadline-prewarning-
    -- if-scheduled`).  Default `true` — the user already sees the
    -- row on its scheduled day, so the pre-warning is redundant
    -- noise.  Set false to keep both.  Per-block override via
    -- `block.skip_deadline_prewarning_if_scheduled`.
    skip_deadline_prewarning_if_scheduled = true,
    -- Sort tokens applied within each day-bucket. Mirrors Emacs
    -- `org-agenda-sorting-strategy`. The first token returning a
    -- non-zero comparison wins. Per-block override via
    -- `block.sorting_strategy = { ... }`.
    --   "time-up", "time-down"
    --   "priority-up", "priority-down"
    --   "category-up", "category-down", "category-keep"
    --   "alpha-up", "alpha-down"
    --   "todo-state-up", "todo-state-down"
    sorting_strategy = { "time-up", "priority-down", "category-keep" },
    -- Row grouping within each day-bucket (org-super-agenda style).
    -- A list of group specs; each spec partitions matching rows under
    -- its title. Predicates AND together; first matching group wins.
    -- See lua/organ/agenda/groups.lua for the full predicate set
    -- (tag, todo, priority, category, has_time, has_deadline,
    -- has_scheduled, pred, discard). Per-block override via
    -- `block.groups = { ... }`.
    groups = nil,
    -- Title for the auto-appended catch-all group (rows that matched
    -- no user group). Set "" to suppress the catch-all entirely.
    groups_catch_all_title = "Other",
    -- Top-of-buffer header line ("Week-agenda (W18):" / "Day-agenda
    -- (W18):" etc.). Set false to suppress.
    view_header = true,
    -- "← now" marker on today's day-bucket. Default on; set false to
    -- suppress.
    now_marker = true,
    -- Template string for the now-marker line. `%s` is replaced by
    -- the wall-clock HH:MM. Mirrors Emacs / nvim-orgmode's
    -- `org-agenda-current-time-string`. The substring "← now" (or
    -- "now") gets the @organ.agenda.now_marker highlight.
    current_time_string = "  %s ┄┄┄┄┄ ← now ─────────────────────────────",
    -- Time grid (Emacs `org-agenda-use-time-grid`). Default ON for
    -- today's bucket only (matches Emacs default). Enable for every
    -- day in the window with `time_grid = { on = "all" }`. Disable
    -- with `time_grid = false`.
    time_grid = { hours = { 8, 10, 12, 14, 16, 18, 20 }, on = "today" },
    -- Time-string leading zero (Emacs `org-agenda-time-leading-zero`).
    -- false (default) → ` 9:00` / `17:00` (compact, Emacs default).
    -- true            → `09:00` / `17:00` (uniform 5-cell column).
    time_leading_zero = false,
    -- Per-category icon prefix (Emacs `org-agenda-category-icon-alist`,
    -- simplified to a flat map).  Prepends the value to the rendered
    -- category column when the category matches.  No-op for unmapped
    -- categories — they pass through unchanged.
    --
    -- Example:
    --   category_icons = { Tasks = " ", Q4Plan = "󰒓 ", Habits = "󰕗 " }
    category_icons = {},
    -- Apply `todo_ignore_*` filters to tag-search views in addition to
    -- the TODO list (Emacs `org-agenda-tags-todo-honor-ignore-options`,
    -- default false).  Useful for users who want their custom
    -- `:Org agenda tags …` commands to follow the same rules as the
    -- global TODO list.
    tags_todo_honor_ignore_options = false,
    -- Start each agenda buffer with the clock report visible (Emacs
    -- `org-agenda-clockreport-mode`).  `gR` toggles per-buffer at any
    -- time; this is just the initial state.
    clockreport_mode = false,
    -- Log mode (Emacs `org-agenda-log-mode-items` + `-start-with-log-
    -- mode`).  When `on_start = true`, the agenda starts with `l`
    -- mode active: CLOSED entries / clock entries / state-change log
    -- lines render as additional rows on the day each event happened.
    -- `items` chooses which event types render.  `l` toggles per-buffer.
    log_mode = {
      -- Emacs `org-agenda-log-mode-items` default is (closed clock).
      items = { "closed", "clock" },
      on_start = false,
    },
    -- Entry-text mode (Emacs `org-agenda-entry-text-mode` + `-maxlines`).
    -- When `on_start = true`, agenda rows include the first
    -- `max_lines` lines of body text under each headline.  `E`
    -- toggles per-buffer.
    entry_text = {
      max_lines = 5,
      on_start = false,
    },
    -- Starter named views available out of the box. Per Rule 1
    -- (replace-on-override), assigning to `views` REPLACES this set;
    -- compose with require("organ.defaults").agenda.views to keep them.
    views = {
      -- :Org agenda todos — every TODO-state headline regardless of
      -- whether it has a SCHEDULED/DEADLINE timestamp. Mirrors Emacs
      -- C-c a t.
      todos = {
        types = { "any" },
        todo = { exclude = { "DONE", "CANCELLED" } },
        group_by = "todo_state",
      },
      -- :Org agenda today — only items scheduled or due today.
      today = {
        from = "today",
        to = "today",
        types = { "scheduled", "deadline" },
        todo = { exclude = { "DONE", "CANCELLED" } },
        include_overdue = true,
      },
      -- :Org agenda next — only headlines in NEXT state.
      next = {
        types = { "any" },
        todo = { include = { "NEXT" } },
        group_by = "none",
      },
      -- :Org agenda overview — block agenda combining the day + the
      -- TODO list, mirroring Emacs's typical `org-agenda-custom-commands`
      -- ("c a a") starter.
      overview = {
        blocks = {
          {
            label = "Today",
            from = "today",
            to = "today",
            types = { "scheduled", "deadline" },
            todo = { exclude = { "DONE", "CANCELLED" } },
            include_overdue = true,
          },
          {
            label = "TODOs",
            types = { "any" },
            todo = { exclude = { "DONE", "CANCELLED" } },
            group_by = "todo_state",
          },
        },
      },
    },
    keymaps = {
      jump = "<CR>",
      refresh = "r",
      close = "q",
      -- gs/gv (vim "go" namespace) instead of bare o/v which would shadow
      -- normal-mode `o` (open new line) and `v` (visual-character mode).
      open_split = "gs",
      open_vsplit = "gv",
      next_item = "j",
      prev_item = "k",
      filter = "/",
      fold = "<Tab>",
      help = "g?",
      todo_cycle = "t", -- cycle TODO state of the source headline
      todo_set = "T", -- pick TODO state from a selection menu
      next_block = "]]", -- jump to next block header
      prev_block = "[[", -- jump to prev block header
      schedule = "s", -- set/update SCHEDULED on the source headline
      deadline = "D", -- set/update DEADLINE on the source headline
      clock_in = "I", -- clock in to the source headline
      clock_out = "O", -- clock out
      refile = "R", -- refile the source subtree
      next_period = "f", -- shift visible date window forward by its own length
      prev_period = "b", -- shift visible date window backward
      today = ".", -- reset date window to today (span preserved)
      -- gd/gw instead of vd/vw — leading `v` would shadow visual mode and
      -- cause a 1-second timeoutlen wait on bare `v` press.
      view_day = "gd",
      view_week = "gw",
      effort_filter = "e", -- prompt for an effort filter (e.g. <30, 1:00..2:00)
    },
  },

  calendar = {
    week_start = "mon",
    -- Show prev / current / next side-by-side in a wider window. Default
    -- false to match the original single-month layout. Toggle with `3`
    -- inside the calendar.
    three_months = false,
    -- Print a one-line keymap reference at the bottom of the calendar.
    footer = true,
    -- Minute step for `+`/`-` on the time field's minute segment
    -- (`:Org schedule` / `:Org deadline` with the time field).  The
    -- hour segment always steps by 1.
    time_step_minutes = 5,
  },

  backlinks = {
    enabled = true,
    refresh_debounce_ms = 300,
    line_format = nil,
    -- Window chrome: opt-in (no surprises). Set `true` to install our
    -- default winbar/statusline, a string for a literal expr, or a
    -- function `function(bufnr) -> string` for full control. nil leaves
    -- the user's existing values alone.
    winbar = nil,
    statusline = nil,
    keymaps = {
      jump = "<CR>",
      open_split = "gs",
      open_vsplit = "gv",
      refresh = "r",
      close = "q",
      help = "g?",
    },
  },

  watcher = {
    enabled = true,
    watch_dirs = {},
    auto_watch_buffers = true,
    delete_grace_ms = 500,
    -- Periodic safety-net rescan. fs_events do the real-time work; this
    -- catches missed events and dirs added when nvim wasn't running.
    -- Bumped from 60s → 5min: at 60s the rescan re-walked the entire
    -- org_dir on every tick, enqueueing every file (each gated by
    -- mtime_skip but still costing a stat + DB query). Multiply by
    -- N files and it becomes a noticeable per-minute UI hiccup.
    rescan_interval_ms = 300000,
    scan_batch_size = 50,
    ignore = { "%.git/", "%.swp$", "^%.#", "~$", "%.tmp$" },
    use_polling = false,
    poll_interval_ms = 5000,
  },

  find = {
    enabled = true,
    -- Backend: "snacks" | "telescope" | "fzf_lua" | "vim_ui_select"
    --   | "auto" | function(items, opts).
    -- "auto" picks the first loaded plugin in this order:
    --   snacks → telescope → fzf-lua → vim_ui_select (built-in fallback).
    -- vim_ui_select uses vim.ui.select so refile / find / capture
    -- work on any nvim install without an extra plugin; users who
    -- want a richer picker install snacks / telescope / fzf-lua and
    -- the auto-detect picks it up on the next call.
    backend = "auto",
    columns = { "level", "todo", "priority", "title", "tags", "backlinks", "path" },
    match_fields = { "title", "tags", "path", "todo", "priority" },
    -- <CR> is implicit -- the picker's `default_action` always
    -- fires on Enter (resolved by each backend's confirm wiring).
    -- This table is ONLY for non-default keys.
    keymaps = {
      split = "<C-s>",
      vsplit = "<C-v>",
      tab = "<C-t>",
      backlinks = "<C-b>",
      create = "<M-CR>",
      jump_to_source = "<C-o>",
    },
  },

  roam = {
    enabled = true,
    dir = vim.fn.expand("~/org/roam"),
    file_template = nil,
    body_template = nil,
    dailies = {
      subdir = "daily",
      template = nil,
    },
    sidebar = {
      width = 50,
    },
  },

  structure = {
    enabled = true,
    -- Mirror Emacs `org-odd-levels-only`: when true, only odd-numbered
    -- star counts are valid heading levels (`*`, `***`, `*****`, ...).
    -- Promote / demote step by 2 stars instead of 1 so each step lands
    -- on the next valid level.  Note: the tree-sitter grammar still
    -- treats `**` as a level-2 heading -- this knob only affects
    -- promote / demote / move ops.  Setting it on a buffer that has
    -- even-level headings will produce mixed-parity output until you
    -- normalize the existing headings.
    odd_levels_only = false,
    keymaps = {
      -- Primary (single-chord, mirrors Emacs M-<arrow>): Alt + h/j/k/l for
      -- promote / move-down / move-up / demote of the subtree at cursor.
      -- Falls back to `<<` / `>>` / `gK` / `gJ` for users on terminals
      -- that don't pass <M-x> through cleanly. Set any binding to false
      -- to disable that single map; keymaps = false disables the whole
      -- block.
      promote_subtree = "<M-h>",
      demote_subtree = "<M-l>",
      move_subtree_up = "<M-k>",
      move_subtree_down = "<M-j>",
      -- Headline-only (without subtree) variants: add Shift to the modifier.
      promote_headline = "<M-S-h>",
      demote_headline = "<M-S-l>",
      -- Vim-native aliases retained so users with no Alt available stay
      -- productive. `<<`/`>>` honor `vim.v.count1` so `2>>` demotes twice.
      promote_subtree_alt = "<<",
      demote_subtree_alt = ">>",
      promote_headline_alt = "<LocalLeader><",
      demote_headline_alt = "<LocalLeader>>",
      move_subtree_up_alt = "gK",
      move_subtree_down_alt = "gJ",
      -- Context-aware "new element below" (Emacs M-RET): insert a new
      -- headline / list item / table row / paragraph appropriate to the
      -- surrounding context. Single chord; falls back to `OrgMetaReturn`
      -- command for users who'd rather invoke it explicitly.
      meta_return = "<M-CR>",
    },
  },

  stuck = {
    project_filter = { tags = { any = { "project" } } },
    next_states = { "NEXT" },
  },

  table = {
    enabled = true,
    keymaps = {
      next_cell = "<Tab>",
      prev_cell = "<S-Tab>",
      menu = "<LocalLeader>|",
    },
  },

  fold = {
    -- Mirrors Emacs default `org-cycle-hide-drawer-startup`: drawers
    -- (LOGBOOK, NOTES, PROPERTIES, custom :NAME:...:END:) start
    -- collapsed when an org buffer is opened. Set to false to keep
    -- them all expanded.
    close_drawers_on_open = true,
    -- Number of trailing blank lines to keep visible after a folded
    -- section, matching Emacs `org-cycle-separator-lines` (default 2).
    -- The LAST `min(blanks, max(N, 1))` blank lines before the next
    -- heading stay outside the section's fold; the rest are hidden
    -- with the section.  N=0 reduces to "always 1 visible" (matches
    -- Emacs).  Set to false to disable and fold every trailing blank
    -- with the section above (the pre-0.x organ.nvim behavior).
    cycle_separator_lines = 2,
    -- Renderer that `organ.fold.foldtext()` returns when your
    -- 'foldtext' option calls into it.  By default organ does NOT
    -- set 'foldtext' itself -- you wire it via your config (see
    -- |organ-config-fold-foldtext| or the README "Foldtext"
    -- section).  Set `auto_foldtext = true` below to have organ
    -- wire it for you.  This setting only chooses the return
    -- shape:
    --   "emacs"   (default) -- treesitter-coloured heading line +
    --                          a trailing `…` when hidden content
    --                          is non-blank.  Returns a list of
    --                          {text, hl} segments on nvim 0.10+.
    --   function(foldstart, foldend) -> string -- custom renderer.
    --   false / nil -- defer to vim's builtin foldtext() text.
    foldtext = "emacs",
    -- Auto-apply: organ sets win-local 'foldtext' on every org
    -- buffer to call into `organ.fold.foldtext()`.  Default `true`
    -- so a fresh-install user sees the org-aware folded heading
    -- (treesitter colours + ellipsis) without any Lua.  Set
    -- `false` to keep your custom 'foldtext' on org buffers --
    -- e.g. when your existing wrapper already delegates to
    -- `organ.fold.foldtext()`, or when you prefer a different
    -- format entirely.  See the README "Foldtext" section for the
    -- wire-it-yourself recipe.  Win-local + ftplugin-scoped, so
    -- non-org buffers always keep your global 'foldtext'.
    auto_foldtext = true,
    -- Auto-apply: organ sets win-local 'statuscolumn' on every
    -- org buffer to a sensible default (`%s` signs column +
    -- line# + organ.fold.statuscolumn_marker for the fold
    -- chevron).  Default `true` so the open/close chevron in
    -- OVERVIEW / CONTENTS state is visible without any Lua; the
    -- `%s` placeholder keeps gitsigns / diagnostic signs
    -- rendering as before.  Set `false` to keep your global
    -- statuscolumn -- pair with the helpers in the README
    -- "Statuscolumn" section for fold-aware behaviour.
    auto_statuscolumn = true,
    keymaps = {
      cycle = "<Tab>",
      cycle_global = "<S-Tab>",
    },
  },

  -- Startup behavior knobs (mirror Emacs `org-startup-*` defcustoms).
  -- These run once when an org buffer enters its FileType.  Each can
  -- be overridden per-buffer by `#+STARTUP:` directives at the top of
  -- the file.
  startup = {
    -- Initial outline fold state (Emacs `org-startup-folded`):
    --   "overview"        — show only top-level headings
    --   "content"         — show all headings, hide content
    --   "showall" / false — fully unfolded
    --   "showeverything"  — fully unfolded INCLUDING drawers (default,
    --                       matches Emacs `org-startup-folded` default)
    --   "fold" / true     — alias for "overview"
    folded = "showeverything",
  },

  -- Star concealment (Emacs `org-hide-leading-stars`).
  -- When `hide = true`, headlines render as `   * Foo` instead of
  -- `*** Foo` — the leading N-1 stars are conceal-replaced with spaces.
  -- Sets the window's conceallevel to 2 on attach (restored on detach).
  stars = {
    hide = false,
  },

  -- Countdown timer (Emacs `org-timer-set-timer`). Used for pomodoro-
  -- style focus sessions. Wired through :Org timer start / :Org timer stop
  -- / :Org timer pause; statusline component at organ.timer.statusline().
  timer = {
    -- Default duration when :Org timer start is called with no argument.
    default_seconds = 25 * 60, -- 25-minute pomodoro
  },

  -- org-modern equivalent: visual upgrades for org buffers. Each stage
  -- opts in independently. DO NOT combine `modern.bullets = true` with
  -- `stars.hide = true`; they touch the same conceal range and the
  -- last-applied wins (non-deterministic). Pick one.
  modern = {
    -- Per-level headline bullets (◉ ○ ◈ ◇ cycling). Replaces the trailing
    -- `*` with a level-indexed glyph, conceals leading N-1 stars as
    -- spaces. Use `glyphs = {…}` to override the cycle.
    bullets = false,
    -- Block frames (#+begin_src / #+end_src). Planned.
    blocks = false,
    -- TODO state and timestamp pill rendering. Planned.
    pills = false,
    -- Pipe-table conceal: `|` -> `│`, `-` -> `─`, `+` -> `┼`, with
    -- smart edge corners on rule rows and optional `┌─┬─┐` /
    -- `└─┴─┘` virtual top/bottom borders.  `<l>`/`<r>`/`<c>` org
    -- alignment-row markers collapse to ←/→/· arrows.
    --   `true` -- enable with defaults
    --   `false` (default) -- disabled
    --   table -- enable with overrides:
    --     {
    --       preset = "light"|"round"|"heavy"|"double",
    --       border_virtual = true|false,        -- default true
    --       alignment_indicator = true|false,   -- default true
    --       pause_in_insert = true|false,       -- default true
    --     }
    table = false,
  },

  indent = {
    -- Virtual indent (mirror Emacs `org-indent-mode`).  Body rows
    -- get an inline virt-text prefix sized so the first body byte
    -- aligns with the title text column of its enclosing headline,
    -- so prose sits visually under the title rather than under the
    -- stars.  Heading rows themselves take a pad of (L-1) *
    -- shift_per_level when stars render as literal `*`; the pad is
    -- skipped under `modern.bullets` or `stars.hide`, which already
    -- supply N-1 conceal-spaces of their own.  Files on disk stay
    -- at column 0; readable in any editor.
    enabled = false,
    shift_per_level = 2,
    hl_group = "Conceal",
    refresh_debounce_ms = 100,

    -- Real indent (mirror Emacs `org-adapt-indentation`).  Unlike
    -- `enabled` above, this rewrites BUFFER TEXT -- body lines get
    -- N spaces prepended that persist on disk.  Only applied by
    -- the formatter (`:Org format` / formatexpr / format_buffer)
    -- and by structure operations that move headlines (promote /
    -- demote / refile / archive).  Does NOT auto-fire on every
    -- keystroke, so manual edits are preserved between reformat
    -- passes.
    --
    -- Values mirror Emacs:
    --   "headline-data"  -> only planning + drawer + property
    --                       lines indent under their headline.
    --                       Body prose stays at column 0.  This
    --                       matches Emacs's default behavior.
    --   true             -> all body lines (planning, drawers,
    --                       prose) indent (level - 1) *
    --                       shift_per_level spaces.
    --   false (default)  -> never modify indentation.
    adapt_indentation = false,
  },

  inline_edit = {
    enabled = true,
    keymaps = {
      increment = "<C-a>",
      decrement = "<C-x>",
    },
    -- When `:Org increment` (`<C-a>`) hits a non-org element, the
    -- fallback chain is:
    --   1. `fallback_increment` / `fallback_decrement` callback (if set)
    --   2. dial.nvim's augend dispatcher (auto-detected; opt out with
    --      `use_dial = false`)
    --   3. Vim's native <C-a> / <C-x>
    -- Set the callback to your own logic if you want it to win over
    -- dial.nvim — useful for plugins like ts-node-action.
    fallback_increment = nil,
    fallback_decrement = nil,
    use_dial = true,
  },

  property = {
    enabled = true,
    keymaps = {
      set = "<LocalLeader>ps",
      delete = "<LocalLeader>pd",
      effort = "<LocalLeader>e", -- :Org set_effort (allowed-values aware)
    },
  },

  complete = {
    enabled = true,
    attachment_dir = nil,
    file_walk_max_results = 500,
    cmp = true,
    blink = true,
    -- When true AND blink.cmp / nvim-cmp is loaded, register an additional
    -- completion source that proposes roam node titles inline as the user
    -- types in any .org buffer (mirrors Emacs `org-roam-completion-everywhere`).
    -- Without a host completion plugin, use :Org roam linkify on-demand.
    roam_everywhere = false,
    -- Drawer-name completion: when typing `:` at the start of a line inside
    -- a headline section, suggest PROPERTIES / LOGBOOK / CLOCK plus any
    -- custom drawer names already in the buffer. Default true.
    drawer = true,
  },

  capture = {
    enabled = true,
    -- Rule 1: user assignment fully replaces these defaults.
    -- Compose with defaults via require("organ.defaults").capture.templates.
    templates = {
      {
        name = "Task",
        key = "t",
        target = { kind = "file_headline", path = "~/org/inbox.org", headline = "Tasks" },
        body = "* TODO %?\n  %u",
      },
      {
        name = "Note",
        key = "n",
        target = { kind = "file", path = "~/org/notes.org" },
        body = "* %?\n  %u",
      },
      {
        name = "Journal",
        key = "j",
        target = { kind = "file_olp_datetree", path = "~/org/journal.org" },
        body = "* %<%H:%M> %?",
      },
    },
    jump_after_finalise = false,
    window = {
      kind = "float", -- "float" | "split" | "vsplit"
      width = 0.6,
      height = 0.4,
      border = "rounded",
      title = "Capture: %s",
      title_pos = "center",
      -- Winbar with template name + finalise/cancel hints, visible in
      -- every window kind. Set false to suppress.
      winbar = true,
    },
    datetree_format = { "%Y", "%Y-%m %B", "%Y-%m-%d %A" },
    keymaps = {
      finalise = "ZZ", -- Vim: "write and close"
      finalise_alt = "<CR>", -- normal mode: Enter to confirm
      cancel = "ZQ", -- Vim: "quit without write"
      cancel_normal = "q", -- normal mode: q closes special buffers
      cancel_insert = nil,
      refile_finalise = "<LocalLeader>w", -- finalise + jump to refile picker
    },
    popup = {
      border = "rounded",
      width = 0.3,
      max_lines = 15,
    },
  },

  -- Priority cookies on headlines. Mirrors Emacs `org-priority-{highest,
  -- lowest, default}`. Letters can be any ASCII range; the convention
  -- is alphabetical (A=highest because it's the "top" letter), but
  -- numeric ranges (1..9) also work. `default` is the priority used
  -- when raising from "no cookie" via inline_edit.raise_priority on a
  -- headline that has no current cookie — actually we use highest for
  -- that, matching Emacs's `^` raise; `default` is reserved for future
  -- features that explicitly need a "default priority" value.
  priority = {
    highest = "A",
    lowest = "C",
    default = "B",
    -- When the cursor is on a headline with NO priority cookie and the
    -- user runs `<C-a>` (raise) / `<C-x>` (lower), the first cycle
    -- jumps to `highest` (raise) or `lowest` (lower) by default.
    -- With this on (Emacs `org-priority-start-cycle-with-default`),
    -- the first cycle adds the `default` priority instead — useful
    -- when "raise" should mean "add a cookie" before pinning to the
    -- top of the range.
    start_cycle_with_default = false,
  },

  todo = {
    sequence = { "TODO", "NEXT", "WAITING", "HOLD", "PROJ", "|", "DONE", "CANCELLED" },
    -- log_done: behavior on active→done transitions. "time" inserts a CLOSED
    -- planning line; "note" also prompts for a LOGBOOK note. nil disables both.
    -- Per-keyword highlight overrides (mirror Emacs `org-todo-
    -- keyword-faces`).  Each value can be a highlight group name
    -- ("WarningMsg") or an `nvim_set_hl` opts table
    -- ({ fg = "#5fafff", bold = true }).  Drives both the agenda
    -- TODO state column and the headline TODO-state highlight in
    -- the source buffer (via `@organ.agenda.todo_<state>`).
    --
    -- Example:
    --   keyword_faces = { WAITING = "WarningMsg",
    --                     NEXT    = { fg = "#5fafff", bold = true } }
    keyword_faces = {},
    log_done = "time",
    log_drawer = "LOGBOOK",
    -- Per-destination-state logging policy for ALL transitions. Mirrors Emacs
    -- per-keyword `(state . "@")` / `(state . "!")` syntax in org-todo-keywords.
    -- Map state→"note" (timestamp + prompt) or "time" (timestamp only).
    -- Setting a state to false explicitly disables logging for that destination.
    log_states = {},
    -- Blanket: log every state transition with a timestamp into the drawer.
    -- Mirrors Emacs `org-log-state-changes` (informally — not a direct equivalent).
    log_state_changes = false,
    -- Mirror Emacs `org-log-into-drawer`. When true (default), state-change
    -- log lines wrap inside the LOGBOOK drawer. When false, they appear as
    -- bare list items immediately after the planning block.
    log_into_drawer = true,
    -- Planning-change logging. Each is "time" | "note" | false.
    --   log_reschedule  fires when SCHEDULED is changed (not first-set).
    --   log_redeadline  fires when DEADLINE is changed (not first-set).
    --   log_refile      fires when a subtree is moved via refile.
    log_reschedule = false,
    log_redeadline = false,
    log_refile = false,
    -- Style for `todo.keymaps.fast_pick` (`:Org todo` with
    -- selection menu).  Mirrors `agenda.dispatcher_style`:
    --   "popup"  (default)  floating window that blocks on
    --                       getcharstr -- stays put regardless of
    --                       async UI plugins (noice / snacks /
    --                       completion) that would overdraw the
    --                       echo-area prompt.
    --   "echo"              nvim_echo + getcharstr; lighter but
    --                       subject to overdraw -- the prompt
    --                       can disappear before the user picks.
    fast_pick_style = "popup",
    -- Indent for newly-inserted planning lines (SCHEDULED:,
    -- DEADLINE:, CLOSED:).  Mirrors Emacs `org-adapt-indentation`:
    --   "adapt"   (default)  heading_level + 1 spaces -- matches
    --                        Emacs `'headline-data` (Org 9.5+ /
    --                        Emacs 30.x default): `* L1` -> 2,
    --                        `** L2` -> 3, `*** L3` -> 4.
    --   <number>             fixed N spaces regardless of depth.
    --                        Older Emacs convention is usually 2.
    --   0 (or false)         flush left.  Matches Emacs
    --                        `org-adapt-indentation = nil`.
    -- Existing-line edits preserve whatever indent is already there;
    -- this only governs the FIRST write under a headline.
    planning_indent = "adapt",
    -- Dependency enforcement on every TODO state transition. Mirrors
    -- Emacs `org-enforce-todo-dependencies = t` and `:ORDERED:` siblings.
    -- A child carrying `:NOBLOCKING: t` is exempt from parent-blocking.
    -- Set to false to disable both parent-blocking and ORDERED-sibling
    -- guards (`:ORDERED:` is then purely informational).
    enforce_dependencies = true,
    -- Opt-in: a headline cannot transition to DONE while any `- [ ]` in
    -- its body is unchecked. Independent of enforce_dependencies.
    enforce_checkbox_dependencies = false,
    keymaps = {
      -- Fast single-keystroke picker (Emacs `org-fast-todo-selection`):
      -- pops a one-line prompt with `[t] TODO  [n] NEXT  ...`; press
      -- one char to set that state.  Access keys auto-derived from
      -- each keyword's first available char unless you annotated them
      -- like `"TODO(t)"`.  This is the primary 2-key chord.
      fast_pick = "<LocalLeader>t",
      -- Menu-style picker (vim.ui.select fallback) for users who
      -- prefer arrow-key navigation over single-key dispatch.
      set = "<LocalLeader>T",
      -- Cycle TODO state forward / backward.  Meta+letter mirrors
      -- the rest of organ's state-change bindings (`<M-h>` / `<M-l>`
      -- promote/demote, `<M-j>` / `<M-k>` move up/down) and stays out
      -- of the way of vim-unimpaired's `]X` / `[X` motion-bracket
      -- family.  Forward is `<M-t>`, backward is the symmetric
      -- shift variant `<M-T>`.
      --
      -- Caveat: a few terminals (Terminal.app, some tmux configs)
      -- collapse `<M-t>` and `<M-T>` into the same byte sequence, so
      -- on those `cycle_back` is unreachable -- the `cycle_back_alt`
      -- arrow chord below works regardless of terminal quirks.
      cycle = "<M-t>",
      cycle_back = "<M-T>",
      -- Emacs-feel alt: `<S-Right>` / `<S-Left>` mirror
      -- `org-shiftright` / `org-shiftleft` exactly.  Vim's default
      -- for these is `W` / `B` (move by WORD); the bindings are
      -- buffer-local to org buffers so `w` / `W` / `b` / `B` still
      -- do the usual word motions outside org.
      cycle_alt = "<S-Right>",
      cycle_back_alt = "<S-Left>",
    },
    calendars = {},
    default_country = nil,
    holidays_cache_dir = nil,
  },

  clock = {
    enabled = true,
    log_drawer = nil, -- nil = inherit from todo.log_drawer (default "LOGBOOK")
    idle_threshold_minutes = nil, -- nil = idle resolution off
    -- Where CLOCK lines are written (mirror Emacs `org-clock-into-
    -- drawer`).  Accepted shapes:
    --   true        — wrap clock entries in the drawer named by
    --                 `log_drawer` (or "LOGBOOK")  [default]
    --   false       — write CLOCK lines bare, immediately under the
    --                 headline (no drawer)
    --   string      — wrap in a drawer with this name (alias for
    --                 setting `log_drawer = "<NAME>"`)
    --   integer N   — bare until the entry count reaches N, then
    --                 promote into a drawer  [TODO: not yet wired;
    --                 falls back to true for now]
    into_drawer = true,
    -- Auto clock-out when the clocked headline transitions into a
    -- DONE-type state (mirror Emacs `org-clock-out-when-done`).
    -- Only fires when the transitioning headline IS the active
    -- clock target — clocking on a different row is left alone.
    -- Default true; set false to keep clocks running across DONE.
    out_when_done = true,
    -- Persist the active clock across nvim restarts (Emacs `org-
    -- clock-persist`).  Already wired via `clock.setup_resume()` —
    -- this surfaces the toggle.  Default true.  Accepted values:
    --   true / "all"       — persist active clock + history
    --   "clock"            — persist only the active clock
    --   "history"          — persist only the recent-clocks list
    --   false              — no persistence
    persist = true,
    -- Idle-time resolution policy (Emacs `org-clock-resolve` family).
    -- When `idle_threshold_minutes` triggers and the user has been
    -- idle, choose how to handle the idle interval:
    --   "prompt"   — interactive popup (default)
    --   "keep"     — silently keep idle minutes as worked time
    --   "subtract" — silently subtract idle from the active clock
    --   "discard"  — clock out at the moment idleness was detected
    idle_resolution = "prompt",
    keymaps = {
      in_ = "<LocalLeader>i", -- buffer-local: clock in to current headline
      out = "<LocalLeader>o", -- clock out of active clock
      cancel = "<LocalLeader>cc", -- cancel active clock
      jump = "<LocalLeader>cj", -- jump to clocked headline
      report = "<LocalLeader>cr", -- open clock report
    },
  },

  -- Refile destinations and picker shape (mirror Emacs `org-refile-
  -- targets` and `org-refile-use-outline-path`).
  --
  -- `targets` is a list of rules; the candidate pool for `:Org refile`
  -- is the union of headlines matching ANY rule.  Each rule:
  --   files      — "agenda_files"      use config.agenda_files
  --                "current"            current buffer's file only
  --                <list>               explicit paths / globs
  --                <function>           returns a list at call time
  --                <glob string>        single glob ("**/*.org")
  --   max_level  — cap on outline depth (3 → only headings at level
  --                ≤ 3 are refile targets)
  --   regex      — (reserved; not yet wired)
  --
  -- nil → no filter; every indexed headline is a refile candidate
  -- (preserves the pre-config behavior).
  --
  -- Example:
  --   targets = {
  --     { files = "agenda_files", max_level = 3 },
  --     { files = "current",      max_level = 5 },
  --   }
  --
  -- `use_outline_path` controls the picker label format:
  --   "outline"      breadcrumb (file → parents → heading)  [default]
  --   "file"         file path + heading
  --   "full"         outline + path
  refile = {
    targets = nil,
    use_outline_path = "outline",
  },

  archive = {
    enabled = true,
    -- Archive destination, in Emacs `org-archive-location` syntax:
    -- `"FILE::HEADLINE"`.
    --   FILE      where to write entries.  `%s` is replaced with the
    --             source file's basename (Emacs convention).
    --             Relative paths resolve against the source's dir;
    --             absolute paths and `~/...` are honored as-is.
    --   HEADLINE  optional wrapper heading (with or without leading
    --             `* `).  When empty, archived subtrees become top-
    --             level headings in the archive file (Emacs default).
    --
    -- Default matches Emacs: `"%s_archive::"` -- sibling `_archive`
    -- file, no wrapper heading.
    --
    -- Override precedence at archive time:
    --   1. `:ARCHIVE:` property on the subtree being archived
    --   2. `#+ARCHIVE:` directive at the buffer top
    --   3. this config value
    --
    -- May also be a function `(src_path) -> location_string` for
    -- dynamic destinations (e.g. dated archive dirs) -- an organ
    -- extension over Emacs's string-only `org-archive-location`.
    location = "%s_archive::",
    -- Heading title for `:Org archive to_sibling` (Emacs
    -- `org-archive-sibling-heading`, default `"Archive"`).
    sibling_heading = "Archive",
    add_metadata = true, -- inject :ARCHIVE_TIME:, :ARCHIVE_FILE:, etc.
    -- When true (default, matches Emacs), write `# Archived entries
    -- from file <path>` once at the top of the archive file the
    -- first time entries are added.  Emacs hardcodes this on
    -- (`org-archive--add-comment`); organ exposes a toggle.  Set to
    -- false to suppress the header line.
    write_source_header = true,
    -- Default action for `:Org archive` (Emacs `org-archive-default-
    -- command`).  One of:
    --   "subtree"            — move the subtree per `location` above
    --                          (default)
    --   "to_archive_sibling" — move the subtree under a `* Archive`
    --                          sibling in the SAME file
    --   "set_archive_tag"    — leave the subtree in place and add the
    --                          `:ARCHIVE:` tag
    default_command = "subtree",
    -- Which context properties to inject when archiving (Emacs
    -- `org-archive-save-context-info`, default
    -- `{ "time","file","olpath","category","todo","itags" }`).  Any
    -- subset of these tokens.  Set `add_metadata = false` to
    -- suppress all property injection regardless.
    save_context_info = { "time", "file", "olpath", "category", "todo", "itags" },
  },

  attach = {
    enabled = true,
    dir = vim.fn.expand("~/org/data"), -- root dir for attachments
    auto_insert_link = true,
    use_symlinks = false, -- copy by default
    -- When true, the attachment dir is git-init'd on first use and every
    -- attach (file / URL / screenshot) auto-commits the new file. Mirrors
    -- Emacs `org-attach-git`. Requires `git` on PATH; otherwise no-op + warn.
    git = false,
    -- Layout for ID-keyed attachment subdirectories under `dir`
    -- (Emacs `org-attach-id-dir-format`).
    --   "two_three"  — `dir/<id[1..2]>/<id[3..]>/`   (default; matches Emacs)
    --   "flat"       — `dir/<full-id>/`
    -- The two_three split keeps directory listings small for very
    -- large attachment sets.
    id_dir_layout = "two_three",
  },

  sparse = {
    enabled = true,
  },

  -- Effort property + clock-budget display. Off the property `:EFFORT:`,
  -- agenda lines render `[1:30]` (estimated) or `[0:45/1:30]` (actual /
  -- estimated) when clock entries exist. `show_in_agenda = false` hides
  -- the column entirely. Recognised value forms: `30`, `1:30`, `2h`,
  -- `30m`, `1.5h`, `1d`, `1w`.
  effort = {
    show_in_agenda = true,
  },

  -- HTML export options.
  --   `mathjax`  string URL or "cdn" or false. When the buffer contains
  --              `$...$` / `\(...\)` / `\[...\]`, MathJax is loaded so the
  --              browser renders math client-side. Default "cdn".
  html = {
    mathjax = "cdn",
  },

  -- Tag inheritance behaviour. Mirrors Emacs `org-tags-inherit-p`.
  --
  --   `inherit`        when true (default), tag-filter queries match a
  --                     headline if any ancestor or #+FILETAGS has the tag.
  --   `display_inherited`  when true, agenda lines render the union of
  --                     direct + inherited tags. Off by default since it
  --                     adds a recursive CTE per agenda refresh.
  tags = {
    inherit = true,
    -- Default true so agenda rows show ancestor + #+FILETAGS tags
    -- (matches Emacs's `org-tags-column`-fed display, which always
    -- includes inherited tags).  The CTE cost is negligible at our
    -- typical row counts (≤ low thousands).
    display_inherited = true,
    alist = {},
    -- Per-tag highlight overrides (mirror Emacs `org-tag-faces`).
    -- Each value can be a highlight group name ("ErrorMsg") or an
    -- `nvim_set_hl` opts table.  Tags with a registered face get
    -- per-tag coloring inside the agenda's tag block; unmapped tags
    -- fall through to `@organ.agenda.tag`.
    --
    -- Example:
    --   faces = { urgent = "ErrorMsg",
    --             work   = "Type",
    --             home   = { fg = "#a3be8c", italic = true } }
    faces = {},
    -- Tags that NEVER inherit even when `tags.inherit = true`
    -- (mirror Emacs `org-tags-exclude-from-inheritance`).  Useful
    -- for marking project roots (`project`), encrypted subtrees
    -- (`crypt`), or any "scope-only" tag whose meaning is local
    -- to the headline that carries it.  Direct application is
    -- unaffected; only propagation to descendants is suppressed.
    --
    -- Example:
    --   exclude_from_inheritance = { "project", "crypt", "noexport" },
    exclude_from_inheritance = {},
    -- `groups`: parent_tag → list of member tags. In :Org sparse_tree match
    -- queries, the parent matches any headline carrying ANY member.
    -- Mirrors Emacs `:startgrouptag` / `:grouptags` / `:endgrouptag` with
    -- a simpler table shape.
    -- Example:
    --   groups = {
    --     gtd     = { "@work", "@home", "@phone" },
    --     project = { "small", "medium", "large" },
    --   }
    groups = {},
    keymaps = {
      set = "<LocalLeader>q", -- mirrors Emacs C-c C-q
    },
  },

  -- Org-tempo: insert-mode `<KEY` + <Tab> expands to a structure block.
  --   `enabled = false` disables the <Tab> mapping entirely.
  --   `expansions` is keyed by the trigger char; each value is a function
  --     returning a list of replacement lines, or a static list.
  tempo = {
    enabled = true,
    expansions = {}, -- merged on top of the built-in s/e/q/v/c/l/h/a set
  },

  -- Multi-file publishing. See lua/organ/publish.lua for project options.
  publish = {
    projects = {},
  },

  -- Org-Babel: src-block execution + tangling.
  --
  --   `confirm_evaluate` (bool, default true)
  --     When true, prompt before running each src block. Set false to skip.
  --   `allow_languages` (list of strings)
  --     Languages that bypass the prompt even when confirm_evaluate=true.
  --     Example: { "lua" } to auto-run lua blocks but still confirm shell.
  babel = {
    confirm_evaluate = true,
    allow_languages = {},
  },

  -- Native CSL citations. `bibliographies` lists extra source files (paths
  -- or globs) on top of any `#+bibliography:` directives in the buffer.
  -- Parsed entries are cached per-file with mtime invalidation, so large
  -- `.bib` files don't re-parse on every completion keystroke.
  cite = {
    bibliographies = {},
  },

  -- Link dispatch. `allow_unsafe` (default false) gates `elisp:` and `shell:`
  -- link execution. Even when true, `shell:` still requires interactive
  -- confirmation; `elisp:` is always rejected (no in-Neovim evaluator).
  links = {
    allow_unsafe = false,
    -- Policy for `:Org store_link` when the cursor is on a headline
    -- (mirror Emacs `org-id-link-to-org-use-id`):
    --   "create"                 — always assign a fresh :ID: when
    --                              missing, then store as `id:UUID`
    --   "use-existing"           — use the existing :ID: when present;
    --                              else fall back to `file::*Headline`
    --                              (default — least intrusive, no
    --                              surprise property-drawer writes)
    --   "create-if-interactive"  — same as "create" for organ (every
    --                              :Org store_link invocation is
    --                              interactive)
    --   false / nil              — never store as `id:`; always emit
    --                              a `file::*Headline` link
    id_link_policy = "use-existing",
    -- ID generation method (Emacs `org-id-method`):
    --   "uuid" (default) — RFC 4122 v7 UUID (organ implementation)
    --   "ts"             — timestamp-based ("YYYYMMDDTHHMMSS-NNN")
    --   <function>       — custom generator returning a string
    id_method = "uuid",
    -- External JSON file mapping ID → file path (Emacs `org-id-
    -- locations-file`).  Reserved for cross-tool interop;
    -- internally organ resolves IDs via the SQLite index.  Set to
    -- a path to enable export of the mapping for external readers.
    id_locations_file = nil,
  },

  -- Image reveal. `inline = true` tries to render images inline via
  -- image.nvim (if the plugin is installed and the terminal supports
  -- the Kitty graphics protocol or sixel); otherwise the file opens in
  -- the system default viewer (`open` / `xdg-open`).
  image = {
    inline = false,
  },

  -- LaTeX preview/rendering.
  --   preview      = "popup" (default) shows a unicode-expanded popup;
  --                  "image" renders the fragment to PNG via pdflatex +
  --                  pdftocairo and displays it inline via image.nvim
  --                  (falls back to popup if tools or image.nvim are
  --                  unavailable).
  --   dpi          = render resolution (default 150).
  --   foreground   = "#RRGGBB" or nil — color the fragment is rendered in.
  --   preamble     = full \documentclass + \usepackage block; nil uses
  --                  a sensible default (standalone + amsmath/amssymb).
  latex = {
    preview = "popup",
    dpi = 150,
    foreground = nil,
    preamble = nil,
  },

  -- Pretty entities: replace `\alpha` with α, `\to` with →, etc. via
  -- conceal extmarks. Off by default; opt in with `enabled = true`.
  -- `extra` lets you add or override mappings (key WITHOUT leading backslash).
  entities = {
    enabled = false,
    extra = {},
  },

  -- Org formatter (paragraph rewrap that preserves headlines,
  -- list bullets, drawers, blocks, tables).  When `enabled = true`,
  -- sets `formatexpr` on org buffers so `gq` rewraps prose
  -- paragraphs.  Wraps to `textwidth` (or 80 if unset).
  --
  -- Auto-format-on-save is intentionally NOT a config flag here —
  -- conform.nvim, none-ls, and the built-in LSP `vim.lsp.buf.format`
  -- (organ exposes textDocument/formatting) all do it cleanly with
  -- their own format-on-save hooks.  See the README "Formatting"
  -- section for recipes.
  format = {
    enabled = true,

    -- Prose rewrap.
    wrap = {
      enabled = true,
      -- Max line width.  `0` means "use the buffer's `textwidth`,
      -- falling back to 80 when textwidth is unset".  Any positive
      -- integer is an explicit cap (overrides textwidth).
      width = 0,
    },

    -- Headline normalisation.
    headline = {
      -- Collapse runs of spaces between stars / todo / comment /
      -- priority / title to a single space.
      normalize_whitespace = true,
      -- Right-align tags on headlines.  Polymorphic:
      --   positive integer N -> tag block's LEFT edge at column N
      --                         (matches Emacs `org-tags-column = N`)
      --   negative integer N -> tag block's RIGHT edge at column |N|
      --                         (matches Emacs `org-tags-column = -N`)
      --   0                  -> one space between title and tags
      --   false              -> no alignment, leave tags as typed
      --   "textwidth"        -> tag RIGHT edge at vim.bo.textwidth
      --                         (falls back to 80 if textwidth is unset)
      --   "textwidth-3"      -> tag RIGHT edge at textwidth - 3
      --   "textwidth+0"      -> equivalent to "textwidth"
      --   "winwidth"         -> tag RIGHT edge at the current window width
      --   "winwidth-3"       -> tag RIGHT edge at winwidth - 3
      --   function           -> called; result is recursively resolved
      --                         (so a function may return any of the above)
      tags_column = "textwidth",
    },

    -- Drawer value alignment.  After format, all `:KEY: value`
    -- lines inside a property drawer get their values aligned to
    -- a common column (one space past the longest key).  Lines
    -- that don't match `:KEY: value` (e.g. LOGBOOK note lines)
    -- are left alone.  Set `align_values = false` to skip.
    drawers = {
      align_values = true,
      -- Minimum spaces between `:KEY:` and `value` even when keys
      -- are uniform length.  Most users want at least 1.
      min_value_indent = 1,
    },

    -- Empty-line policy.
    blanks = {
      -- Number of blank lines before each headline.  "auto" leaves
      -- existing spacing alone; an integer enforces exactly that
      -- many.  Mirrors Emacs `org-blank-before-new-entry`.
      before_headline = "auto",
      -- Same for `#+BEGIN_*` blocks.
      before_block = "auto",
      -- Collapse runs of more than N consecutive blank lines to N.
      -- `0` disables the collapse (any run length is preserved).
      collapse_runs = 0,
      -- Strip blank lines at end-of-buffer.
      trim_trailing = true,
      -- Buffer ends with exactly one newline.
      ensure_final_newline = true,
    },

    -- Per-line cleanup: strip trailing whitespace.
    trim_trailing_whitespace = true,

    -- Tables.  When enabled, format runs `tablature.realign` on
    -- every pipe-table region in the buffer (column widths
    -- normalised, separator rows expanded to match).
    tables = {
      realign = true,
    },

    -- Lists.  Re-sequence ordered list numbering (`1.` `2.` `3.`)
    -- per contiguous block.  Bullet style (`-`/`+`/`*`) is left
    -- alone; only the `1.`/`1)` numbering is repaired.
    lists = {
      repair_numbering = true,
    },
  },

  -- Inline emphasis + link concealment (mirror Emacs `org-hide-
  -- emphasis-markers` and `org-link-descriptive`).  The conceal
  -- walker is ALWAYS attached on FileType=org so the marks are
  -- placed regardless of `enabled`.  The marks have NO visual
  -- effect when `conceallevel = 0` (default), so users get
  -- conceal-on-demand: set `conceallevel = 2` on the buffer or
  -- window and the marks render immediately.
  --
  -- `enabled = true` additionally bumps `conceallevel = 2` on
  -- attach so concealment is on by default for org buffers
  -- (Emacs's `org-link-descriptive = t` default).  Default false
  -- to preserve Neovim's "explicit conceallevel" expectation;
  -- users opt in with `emphasis.enabled = true`.
  --
  -- Per-element keys gate which markup is concealed.  Set any to
  -- `false` to keep that element's syntax visible (e.g. show raw
  -- `*bold*` markers but still hide link brackets).  Toggle at
  -- runtime via `:Org conceal toggle <element>`.
  emphasis = {
    enabled = false,
    bold = true,
    italic = true,
    underline = true,
    strike = true,
    verbatim = true,
    code = true,
    links = true,
  },

  -- Agenda alarms: notify before each scheduled time today.  Disabled by
  -- default; opt in with `enabled = true`.  Uses libuv timers, no daemon.
  alarms = {
    enabled = false,
    -- Minutes-before-due to fire alarms.  `0` means "at exactly the due time".
    lead_minutes = { 10, 0 },
    -- Custom callback: function(row, lead_minutes, fire_ts).  Default uses
    -- vim.notify with "<title> in N min" / "<title> — now" / "— overdue".
    -- Only used when local_schedule = false (in-process delivery).
    notify = nil,
    -- How often to rescan today's agenda for new/changed items.  Defaults
    -- to 10 minutes; the `indexed` event also triggers an immediate rescan.
    scan_interval_seconds = 600,
    -- Route reminders through the OS scheduler (LaunchAgent on macOS, at(1)
    -- or systemd-run --user on Linux, schtasks on Windows) so they fire
    -- even when Neovim is closed. When false (default), only fires while
    -- Neovim is running. See lua/organ/notifier/ for the implementation.
    local_schedule = false,
    -- How far ahead (in hours) to schedule when local_schedule = true.
    -- Larger windows cover more "Neovim closed" time at the cost of more
    -- OS-scheduler entries; 48h covers an overnight + a workday.
    lookahead_hours = 48,
  },

  -- Speed commands: single-key dispatch when cursor is at column 0 of a
  -- headline (Emacs `org-use-speed-commands`).  Disabled by default since
  -- it shadows Vim normal-mode keys; opt-in with `enabled = true`.
  speed = {
    enabled = false,
    -- Set a key to false to disable that single binding; set the whole
    -- `commands` table to false to disable all bindings while keeping
    -- the feature on for programmatic dispatch.
    commands = {
      n = "next_visible",
      p = "prev_visible",
      f = "fold_cycle",
      F = "fold_cycle_global",
      t = "todo_cycle",
      T = "todo_set",
      s = "schedule",
      d = "deadline",
      a = "archive",
      A = "archive_to_sibling",
      I = "clock_in",
      O = "clock_out",
      g = "agenda",
      c = "capture",
      ["?"] = "show_help",
      ["<"] = "promote",
      [">"] = "demote",
      U = "move_up",
      D = "move_down",
    },
  },

  -- Global keymaps: registered from any buffer when setup() runs.
  -- Rule 2: set any value to false to disable that single keymap.
  --         Set the whole block to false to disable all global keymaps.
  --         Override with a different lhs by setting the value to a string.
  global_keymaps = {
    capture = "<Leader>oc",
    agenda = "<Leader>oa",
    find = "<Leader>of",
    find_file = "<Leader>oF",
    find_link = "<Leader>ol",
    roam = "<Leader>or",
    roam_daily_today = "<Leader>od",
    clock_in = "<Leader>oi",
    clock_out = "<Leader>oo",
    clock_report = "<Leader>oR",
    archive_subtree = "<Leader>oA",
    schedule = "<Leader>os",
    deadline = "<Leader>oD", -- uppercase D: <Leader>od is daily-today
    id_create = false, -- no global default; run from inside headline
    scan = false, -- administrative; no default global keymap
    status = false, -- administrative; no default global keymap
    narrow = "<Leader>on",
    widen = "<Leader>oN",
    store_link = "<Leader>oS", -- capital S; lowercase is sparse
    insert_link = false, -- contextual; no global default
    attach = "<Leader>o@",
    attach_open = false, -- contextual
    cut_subtree = false, -- contextual; users opt-in
    copy_subtree = false, -- contextual; users opt-in
    paste_subtree = false, -- contextual; users opt-in
  },

  -- In-process LSP server.  When enabled, every org buffer gets
  -- an in-process LSP client attached on FileType=org.  Exposes:
  --   documentSymbol, workspace/symbol, definition, references,
  --   hover, completion, rename, codeAction, foldingRange,
  --   documentLink, formatting, diagnostic.
  --
  -- Default `true`: built-in `K` (hover), `gd` (definition),
  -- `gr` (references), `<F2>` (rename) all work out of the box;
  -- aerial / symbols-outline / telescope-lsp-* gain native org
  -- support without any extra wiring.  Users who explicitly
  -- don't want a per-buffer LSP client opt out with
  -- `lsp = { enabled = false }`.
  lsp = {
    enabled = true,
  },

  on_index = nil,
  on_scan_done = nil,
  on_error = nil,
}
