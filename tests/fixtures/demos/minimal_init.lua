-- Minimal init for demo recordings.  Loaded via:
--
--   nvim -u tests/fixtures/demos/minimal_init.lua \
--        -c 'lua DemoBoot()' \
--        tests/fixtures/demos/<file>.org
--
-- All setup that needs to finish BEFORE the user's first keystroke
-- lives in `DemoBoot()`.  vhs runs `-c` synchronously between
-- init.lua and the first input event, so calling DemoBoot() via
-- `-c 'lua DemoBoot()'` lets the tape be deterministic regardless
-- of how slow boot is on a given machine -- no Sleep timing to
-- tune per tape.
--
-- Isolation: db_path + a per-run COPY of tests/fixtures/demos so
-- the user's real organ.db isn't polluted and capture / refile /
-- roam writes don't accumulate on disk.

local repo_root = vim.fn.fnamemodify(vim.fn.expand("<sfile>:p:h"), ":h:h:h")
vim.opt.runtimepath:prepend(repo_root)
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/organ")
-- Optional deps that ship as test/demo deps in tests/deps/:
--   * tablature.nvim — table editing helpers used by some demos
--   * narrow.nvim    — narrow-to-region helper
--   * snacks.nvim    — picker UI for find / refile / capture demos
--                      (plugin falls back to vim.ui.select without it,
--                      but the demo looks nicer with the snacks UI)
for _, dep in ipairs({ "tablature.nvim", "narrow.nvim", "snacks.nvim", "catppuccin" }) do
  local p = repo_root .. "/tests/deps/" .. dep
  if vim.uv.fs_stat(p) then
    vim.opt.runtimepath:prepend(p)
  end
end
-- Force snacks's picker to load so find.backend = "auto" detects
-- it on the very first :Org refile / :Org find without waiting for
-- a lazy trigger.  No-op when snacks isn't on the rtp.  Snacks
-- uses Nerd Font glyphs throughout its UI; the demo tapes use
-- `Set Font "JetBrainsMono Nerd Font Mono"` to render them
-- correctly (CI installs the font; local users need it via brew
-- install --cask font-jetbrains-mono-nerd-font on macOS or the
-- equivalent on Linux/Windows).
pcall(require, "snacks.picker")

vim.opt.swapfile = false
vim.opt.laststatus = 0
vim.opt.cmdheight = 2
vim.opt.number = true
vim.opt.relativenumber = false

-- Render foldopen / foldclose with single-cell ASCII chars so the
-- chevron is unambiguous in vhs's chromium-rendered terminal.
-- `fold = " "` drops vim's default `·` filler that otherwise
-- stretches a dotted line across the rest of the folded row --
-- organ's foldtext is self-contained, the dotted fill is noise.
-- The foldtext + statuscolumn wiring uses `fold.auto_foldtext = true`
-- and `fold.auto_statuscolumn = true` in setup() below -- showcasing
-- the opt-in auto-apply path so the GIF doubles as a wiring example.
vim.opt.fillchars:append({ foldopen = "v", foldclose = ">", fold = " " })

-- Determinism across rendering environments:
--   * encoding utf-8 + ambiwidth=single match nvim's defaults but
--     pin them so a chromium-rendered terminal (used by vhs) can't
--     mis-measure box-drawing chars and shift columns by one cell.
--   * termguicolors so colorscheme directives (catppuccin etc.)
--     render with their actual palette rather than the 16-color
--     fallback, which differs visibly between terminals.
vim.opt.encoding = "utf-8"
vim.opt.ambiwidth = "single"
vim.opt.termguicolors = true

-- Catppuccin (Mocha flavour) for a consistent palette across
-- machines.  Falls back silently to nvim's default theme when
-- the rtp dep isn't present.
pcall(vim.cmd.colorscheme, "catppuccin-mocha")

-- Visible keystroke overlay.  vim's built-in `showcmd` only flashes
-- partial commands for normal-mode multi-key sequences; for demo
-- recordings we want EVERY keypress (single-letter commands too,
-- and cmdline-mode chars) to read clearly to a viewer.  A floating
-- window sits in the bottom-right corner showing the last key with
-- a short fade — uses `vim.on_key` so it captures pre-mapping
-- input rather than post-mapping (so 'l' shows even when 'l' is
-- mapped to something else).
do
  local ns = vim.api.nvim_create_namespace("organ_demo_keylog")
  local last_text = ""
  local last_at = 0
  local fade_ms = 1200
  local floatbuf = vim.api.nvim_create_buf(false, true)
  local floatwin

  local function close_float()
    if floatwin and vim.api.nvim_win_is_valid(floatwin) then
      pcall(vim.api.nvim_win_close, floatwin, true)
    end
    floatwin = nil
  end

  local function open_float()
    close_float()
    local cols = vim.o.columns
    local rows = vim.o.lines
    floatwin = vim.api.nvim_open_win(floatbuf, false, {
      relative = "editor",
      width = math.max(8, #last_text + 4),
      height = 1,
      row = rows - 4,
      col = cols - math.max(8, #last_text + 4) - 2,
      style = "minimal",
      border = "rounded",
      focusable = false,
      noautocmd = true,
      zindex = 250,
    })
    -- Keep the buffer modifiable so subsequent keystrokes can
    -- update it.  Setting modifiable=false after the first write
    -- crashed every later keypress with `Buffer is not 'modifiable'`
    -- (the buffer is internal -- no user is editing it directly,
    -- so the read-only protection adds no safety).
    vim.bo[floatbuf].modifiable = true
    vim.api.nvim_buf_set_lines(floatbuf, 0, -1, false, { " " .. last_text .. " " })
    vim.wo[floatwin].winhl = "Normal:Visual,FloatBorder:Special"
  end

  local timer = vim.uv.new_timer()
  vim.on_key(function(_, typed)
    if typed == nil or typed == "" then
      return
    end
    -- keytrans turns escape sequences into readable form (<CR>,
    -- <Esc>, <C-c>, etc.) instead of raw bytes.
    local pretty = vim.fn.keytrans(typed)
    if pretty == "" then
      return
    end
    last_text = pretty
    last_at = vim.uv.hrtime()
    vim.schedule(open_float)
    if timer then
      timer:stop()
      timer:start(
        fade_ms,
        0,
        vim.schedule_wrap(function()
          if vim.uv.hrtime() - last_at >= fade_ms * 1e6 then
            close_float()
          end
        end)
      )
    end
  end, ns)
end

local tmp_root = vim.fn.tempname()
vim.fn.mkdir(tmp_root, "p")
local fixtures_src = repo_root .. "/tests/fixtures/demos"
local org_dir = tmp_root .. "/org"
vim.fn.mkdir(org_dir, "p")
for _, file in ipairs(vim.fn.readdir(fixtures_src)) do
  if file:match("%.org$") then
    vim.fn.writefile(vim.fn.readfile(fixtures_src .. "/" .. file), org_dir .. "/" .. file)
  end
end

require("organ").setup({
  db_path = tmp_root .. "/organ.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false, -- DemoBoot does scan_blocking instead
  watcher = { enabled = false },
  notifier = { enabled = false },
  capture = {
    templates = {
      {
        name = "Task",
        key = "t",
        target = {
          kind = "file_headline",
          path = org_dir .. "/inbox.org",
          headline = "Inbox",
        },
        body = "* TODO %?\n  %u",
      },
      {
        name = "Note",
        key = "n",
        target = {
          kind = "file_headline",
          path = org_dir .. "/inbox.org",
          headline = "Inbox",
        },
        body = "* %?\n  %u",
      },
      {
        name = "Bookmark",
        key = "b",
        target = {
          kind = "file_headline",
          path = org_dir .. "/inbox.org",
          headline = "Inbox",
        },
        body = "* [[%?][title]]\n  %u",
      },
    },
    -- Larger float than the default (60% / 40%) so demo viewers can
    -- read the captured body comfortably.  Real users rarely need
    -- this much room for a one-line task; the demo isn't a
    -- representative size for daily use.
    window = {
      width = 0.8,
      height = 0.6,
    },
  },
  refile = {
    targets = {
      { file = org_dir .. "/projects.org", max_level = 2 },
    },
  },
  roam = { directory = org_dir },
  fold = {
    -- Opt-in auto-apply: organ wires win-local 'foldtext' to its
    -- emacs-style renderer and 'statuscolumn' to its sensible
    -- default (line# + fold chevron).  No Lua wrapper required.
    auto_foldtext = true,
    auto_statuscolumn = true,
  },
  todo = {
    -- Demo-only sequence: no `@` annotations.  In real use we'd
    -- annotate (e.g. `WAIT(w@)`) so transitioning to WAIT prompts for
    -- a note -- but vhs typing fires synthetic keystrokes that get
    -- consumed by the note prompt instead of executing as commands.
    -- Keep only the fast-selection keys; demo cycles cleanly.
    sequence = { "TODO(t)", "WAIT(w)", "NEXT(n)", "|", "DONE(d)", "CANCELED(c)" },
  },
  -- Conceal `[[id:foo][title]]` -> `title` in the demo.  Real users
  -- opt in via emphasis.enabled = true; the demo always renders this
  -- way so screenshots show the same thing the readme promises.
  emphasis = {
    enabled = true,
  },
})

-- Capture :messages on exit so the Makefile can detect post-render
-- errors that vhs would otherwise just bake into the GIF (E-codes,
-- "not modifiable", Lua stack traces, "Press ENTER" prompts, etc.).
-- The Makefile sets DEMO_LOG_PATH per render; absent it, we no-op
-- (so this init also works for non-vhs interactive use).
do
  local logpath = os.getenv("DEMO_LOG_PATH")
  if logpath and logpath ~= "" then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        local ok, msgs = pcall(vim.api.nvim_exec2, "messages", { output = true })
        local body = (ok and msgs and msgs.output) or ""
        pcall(vim.fn.writefile, vim.split(body, "\n", { plain = true }), logpath)
      end,
    })
  end
end

-- Synchronous boot: re-edit the file the user passed against the
-- tmp copy, then index.  Called via `-c 'lua DemoBoot()'` so it
-- runs AFTER init.lua and BEFORE the first user keystroke -- vhs
-- timing is decoupled from boot duration.
function DemoBoot()
  local cmdline_arg = vim.fn.argv(0)
  if cmdline_arg and cmdline_arg ~= "" then
    local basename = vim.fn.fnamemodify(cmdline_arg, ":t")
    local copy = org_dir .. "/" .. basename
    if vim.uv.fs_stat(copy) then
      vim.cmd("edit " .. vim.fn.fnameescape(copy))
      pcall(vim.cmd, "bwipeout! " .. vim.fn.fnameescape(cmdline_arg))
    end
  end
  -- chdir into org_dir so subsequent tape commands like
  -- `:vsplit projects.org` resolve to the tmp copy (which is what
  -- the picker / refile / etc. operate on), not the tracked
  -- fixture under tests/fixtures/demos/.  Without this chdir, a
  -- tape's :vsplit opens the tracked file in a window while
  -- refile mutates the tmp copy in a separate buffer -- the
  -- visible window never reflects the move.
  pcall(vim.cmd, "lcd " .. vim.fn.fnameescape(org_dir))
  pcall(require("organ").scan_blocking, org_dir, 5000)
end
