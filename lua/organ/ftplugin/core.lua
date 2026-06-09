-- lua/organ/ftplugin/core.lua
-- Buffer-local attach for the main FileType=org callback.
-- Installs: TODO keymaps, fold opts, indent, completion, clock keymaps.

local M = {}

function M.attach(bufnr)
  local organ = require("organ")
  local cfg = organ.config

  -- Pick up any buffer-local `#+TODO:` directives so keywords
  -- introduced inline (e.g. `WAIT`, `SOMEDAY`) get the active/done
  -- highlight coloring without a config change.  Re-runs on
  -- BufWritePost so edits to the directive line take effect on save.
  pcall(function()
    require("organ.highlights").register_buffer_todo_keywords(bufnr)
  end)
  local hl_group = vim.api.nvim_create_augroup("organ_buftodo_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged" }, {
    group = hl_group,
    buffer = bufnr,
    callback = function()
      pcall(function()
        require("organ.highlights").register_buffer_todo_keywords(bufnr)
      end)
    end,
  })

  local function map(lhs, fn, desc)
    if lhs == nil or lhs == false then
      return
    end
    vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      callback = fn,
      desc = desc,
    })
  end

  -- TODO keymaps (opt-in via config.todo.keymaps).
  -- Rule 2: keymaps = false disables all todo bindings.
  local cfg_todo = cfg.todo or {}
  local km_todo = cfg_todo.keymaps ~= false and (cfg_todo.keymaps or {}) or {}
  local function do_cycle()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local err = require("organ.todo").cycle(bufnr, line)
    if err then
      require("organ.notify").error(err)
    end
  end
  local function do_cycle_back()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local err = require("organ.todo").cycle_back(bufnr, line)
    if err then
      require("organ.notify").error(err)
    end
  end
  map(km_todo.cycle, do_cycle, "Cycle TODO state forward")
  map(km_todo.cycle_alt, do_cycle, "Cycle TODO state forward (alt)")
  map(km_todo.cycle_back, do_cycle_back, "Cycle TODO state backward")
  map(km_todo.cycle_back_alt, do_cycle_back, "Cycle TODO state backward (alt)")
  map(km_todo.fast_pick, function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    require("organ.todo")._fast_select(bufnr, line)
  end, "Fast TODO state pick (one keystroke)")
  map(km_todo.set, function()
    local choices = { "(none)" }
    for _, k in ipairs((cfg.todo or {}).sequence or {}) do
      if k ~= "|" then
        choices[#choices + 1] = k
      end
    end
    vim.ui.select(choices, { prompt = "TODO state: " }, function(choice)
      if not choice then
        return
      end
      local state = choice == "(none)" and nil or choice
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local err = require("organ.todo").set(bufnr, line, state)
      if err then
        require("organ.notify").error(err)
      end
    end)
  end, "Pick TODO state from menu")

  -- Fold options.  Use organ's headline-depth foldexpr instead of
  -- `vim.treesitter.foldexpr()` because the latter conflated list /
  -- drawer / block nodes with outline depth and broke heading
  -- folding in files containing lists.  See `lua/organ/fold.lua` for
  -- the algorithm.  These are window-local options; setting them
  -- once at FileType time covers the FIRST window the buffer enters,
  -- but a `:vsplit` / `wincmd s` later spawns another window where
  -- foldexpr defaults back to "" -- re-apply on BufWinEnter so every
  -- window the buffer lands in gets the same options.
  --
  -- `foldtext` and `statuscolumn` are auto-applied (defaults.lua sets
  -- both `fold.auto_foldtext` and `fold.auto_statuscolumn` to `true`).
  -- Opt out by setting either to `false` in your config.  When on,
  -- organ writes the win-local option here using a flat `v:lua.<name>()`
  -- form (avoids the nvim TUI option-eval bug with chained
  -- `v:lua.require` calls).
  local cfg_fold_top = cfg.fold or {}
  -- `nvim_set_option_value(name, val, { win = 0 })` without a scope is
  -- equivalent to `:set` -- it sets BOTH the win-local AND the global
  -- value.  For visually-customised options (foldtext, statuscolumn,
  -- fillchars, winhighlight, conceallevel) clobbering the global means
  -- the user's own setting is gone, and our wrappers' non-org fallback
  -- (which reads vim.go.foldtext) hits its own string and falls to
  -- vim's default.  Always pass `scope = "local"` for win-only writes.
  local function setlocal(name, value)
    pcall(vim.api.nvim_set_option_value, name, value, { win = 0, scope = "local" })
  end
  local function apply_fold_window_opts()
    pcall(function()
      setlocal("foldmethod", "expr")
      setlocal("foldexpr", "v:lua.require'organ.fold'.foldexpr(v:lnum)")
      setlocal("foldenable", true)
      -- `foldminlines = 0` lets the foldexpr's body folds (often a single
      -- line under a heading) actually close — the default of 1 silently
      -- drops 1-line folds that sit between adjacent transitions.
      setlocal("foldminlines", 0)
      -- Both auto-foldtext and auto-statuscolumn point at globals
      -- (`_organ_foldtext`, `_organ_statuscolumn`) defined when
      -- `organ.fold` is required.  Setting the option strings before
      -- the module loads leaves a window where vim evaluates the
      -- option and hits a nil global -- e.g. CursorMoved firing
      -- elsewhere triggers a redraw before the foldexpr (which
      -- lazily requires organ.fold) runs.  Force the require so the
      -- globals are guaranteed defined by the time vim reads either
      -- option string.
      pcall(require, "organ.fold")
      if cfg_fold_top.auto_foldtext == true then
        setlocal("foldtext", "v:lua._organ_foldtext()")
        -- Drop vim's `·` fold filler on this window.  organ's
        -- foldtext is self-contained -- the dotted fill drawn past
        -- it across the rest of the folded row is visual noise.
        -- Win-local fillchars REPLACES (not merges) the global, so
        -- we manually merge: keep every existing entry, override
        -- the `fold:` slot to space.
        local fc = vim.go.fillchars or ""
        local parts, has_fold = {}, false
        for piece in (fc .. ","):gmatch("([^,]+),") do
          if piece:match("^fold:") then
            parts[#parts + 1] = "fold: "
            has_fold = true
          elseif piece ~= "" then
            parts[#parts + 1] = piece
          end
        end
        if not has_fold then
          parts[#parts + 1] = "fold: "
        end
        setlocal("fillchars", table.concat(parts, ","))
      end
      if cfg_fold_top.auto_statuscolumn == true then
        setlocal("statuscolumn", "%!v:lua._organ_statuscolumn()")
      end
      -- Remap the per-window Folded highlight to OrgFolded (bg = NONE)
      -- so folded heading lines blend with Normal's background.  The
      -- foldtext segments keep their natural foreground (TODO, title,
      -- tags) on top.  Append to whatever the user already had set in
      -- winhighlight rather than clobber it.
      local prev_wh = vim.api.nvim_get_option_value("winhighlight", { win = 0 })
      if not prev_wh:find("Folded:") then
        local new_wh = (prev_wh == "" and "Folded:OrgFolded") or (prev_wh .. ",Folded:OrgFolded")
        setlocal("winhighlight", new_wh)
      end
    end)
  end
  apply_fold_window_opts()
  -- foldlevel only on the initial attach -- BufWinEnter shouldn't
  -- reset it back to 99 every time the user re-enters the window
  -- (would override <S-Tab> state).
  setlocal("foldlevel", 99)
  local fold_win_group = vim.api.nvim_create_augroup("organ_foldwin_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = fold_win_group,
    buffer = bufnr,
    callback = apply_fold_window_opts,
  })
  -- BufWinLeave: org buffer is leaving this window (user did :e foo.lua,
  -- :bnext, etc.).  Clear our win-local overrides so the next buffer in
  -- this window inherits its own / global values.  Without this, the
  -- win-local 'foldtext = v:lua._organ_foldtext()' / 'winhighlight =
  -- Folded:OrgFolded' / 'fillchars = fold: ' / raised conceallevel can
  -- linger and visibly degrade the next buffer's fold display
  -- (`_organ_foldtext`'s non-org fallback returns vim.fn.foldtext() which
  -- in nvim 0.12 is a plain string -- vim renders it with Folded only,
  -- losing per-token syntax highlights that a treesitter-aware default
  -- would have shown).  `:setlocal opt<` reverts the win-local override
  -- to inherit from global.
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = fold_win_group,
    buffer = bufnr,
    callback = function()
      pcall(
        vim.cmd,
        "setlocal foldtext< statuscolumn< fillchars< winhighlight<"
          .. " conceallevel< concealcursor<"
      )
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = fold_win_group,
    buffer = bufnr,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, fold_win_group)
    end,
  })

  -- Initial outline fold state (Emacs `org-startup-folded`).  Honor
  -- a buffer-local `#+STARTUP:` override (overview/content/showall/
  -- showeverything/fold/nofold) when present, else fall back to the
  -- global `startup.folded` config.  The four resolved states map
  -- 1:1 onto organ.fold's apply_* helpers, so this path and the
  -- <S-Tab> cycle path stay in lock-step: previously the startup
  -- path inlined its own foldlevel writes that disagreed with
  -- cycle_global (overview here was foldlevel=1, cycle_global's
  -- overview is foldlevel=0), and the file opened in a state S-Tab
  -- could never return to.
  --
  -- Scratch-style org buffers (capture float, etc.) opt out via
  -- `b:organ_no_startup_fold = true` so a 1-2 line entry isn't
  -- folded into a single headline-only line.
  if not vim.b[bufnr].organ_no_startup_fold then
    local folded = (cfg.startup or {}).folded
    -- Scan the first 50 lines for #+STARTUP: directives.
    local lines =
      vim.api.nvim_buf_get_lines(bufnr, 0, math.min(50, vim.api.nvim_buf_line_count(bufnr)), false)
    for _, l in ipairs(lines) do
      local val = l:match("^%s*#%+[Ss][Tt][Aa][Rr][Tt][Uu][Pp]:%s*(.*)$")
      if val then
        for tok in val:gmatch("%S+") do
          local lt = tok:lower()
          if
            lt == "overview"
            or lt == "content"
            or lt == "showall"
            or lt == "showeverything"
            or lt == "fold"
            or lt == "nofold"
          then
            folded = lt
          end
        end
      end
    end
    if folded == "fold" or folded == true then
      folded = "overview"
    end
    if folded == "nofold" or folded == false then
      folded = "showall"
    end
    local STARTUP_TO_STATE = {
      overview = "overview",
      content = "content",
      showall = "show_all",
      showeverything = "show_everything",
    }
    local state = STARTUP_TO_STATE[folded]
    if state then
      -- Defer one tick: the TS parser + foldexpr need to have
      -- populated before close_all_drawers / contents.enter can
      -- find ranges to act on.  Resolve the winid at fire time so
      -- nvim_buf_call's "current window" doesn't land on a capture
      -- float that happens to be focused.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        local target_winid = vim.fn.bufwinid(bufnr)
        if target_winid <= 0 then
          return
        end
        require("organ.fold").apply_global_state(state, target_winid, bufnr)
      end)
    end
  end -- if not organ_no_startup_fold

  -- Fold keymaps (opt-in via config.fold.keymaps).
  -- Rule 2: keymaps = false disables all fold bindings.
  local cfg_fold = cfg.fold or {}
  local km_fold = cfg_fold.keymaps ~= false and (cfg_fold.keymaps or {}) or {}
  map(km_fold.cycle, function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    require("organ.fold").cycle(bufnr, line)
  end, "Cycle fold (heading 3-state)")
  map(km_fold.cycle_global, function()
    require("organ.fold").cycle_global(bufnr)
  end, "Cycle fold (global) / toggle drawer")

  -- Auto-attach indent if enabled.
  if (cfg.indent or {}).enabled then
    require("organ.indent").attach(bufnr)
  end

  -- Insert-mode link completion auto-trigger.
  if (cfg.complete or {}).enabled then
    local group = vim.api.nvim_create_augroup("organ_complete_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("TextChangedI", {
      group = group,
      buffer = bufnr,
      callback = function()
        require("organ.complete").schedule_open(bufnr)
      end,
    })
  end

  -- Clock keymaps (opt-in; gated by enabled flag).
  local cfg_clock = cfg.clock or {}
  if cfg_clock.enabled ~= false then
    -- Rule 2: keymaps = false disables all clock bindings.
    local km_clock = cfg_clock.keymaps ~= false and (cfg_clock.keymaps or {}) or {}
    map(km_clock.in_, function()
      require("organ.clock").start()
    end, "Clock in")
    map(km_clock.out, function()
      require("organ.clock").stop()
    end, "Clock out")
    map(km_clock.cancel, function()
      require("organ.clock").cancel()
    end, "Cancel active clock")
    map(km_clock.jump, function()
      require("organ.clock").jump()
    end, "Jump to clocked headline")
    map(km_clock.report, function()
      require("organ.clock").report()
    end, "Open clock report")
  end

  -- Speed commands: cursor-at-column-0-of-headline single-key dispatch.
  if (cfg.speed or {}).enabled then
    require("organ.speed").attach(bufnr)
  end

  -- Pretty entities (org-pretty-entities): conceal `\alpha` → α etc.
  if (cfg.entities or {}).enabled then
    require("organ.entities").attach(bufnr)
  end

  -- Shared decoration provider infrastructure (organ.decoration).
  -- Individual decoration modules register as providers when their
  -- module is loaded (top-level `decoration.register`); this single
  -- attach wires the per-buffer `nvim_buf_attach` + `on_line` dispatch.
  -- Inline emphasis + link concealment (Emacs `org-hide-emphasis-
  -- markers` + `org-link-descriptive`) runs through this path -- its
  -- marks have no visual effect at `conceallevel = 0`, so the user
  -- opts in by setting `conceallevel = 2` or via `:Org conceal toggle`.
  pcall(function()
    require("organ.conceal")
  end)
  pcall(function()
    require("organ.decoration").attach(bufnr)
  end)

  -- Description-list separator highlighter: walks list_item nodes
  -- and emits per-range extmarks for `term ::` shapes so terms +
  -- separator render distinctly from definition body.  The grammar
  -- doesn't expose `term`/`definition` as fields, so this Lua
  -- post-walker fills the gap.
  pcall(function()
    require("organ.description_list").attach(bufnr)
  end)

  -- Formatter: hook `gq` to organ.format (paragraph rewrap that
  -- preserves headlines / lists / drawers / blocks / tables).
  -- Auto-format-on-save is delegated to conform.nvim / none-ls /
  -- vim.lsp.buf.format — see README "Formatting".
  if (cfg.format or {}).enabled ~= false then
    pcall(function()
      vim.api.nvim_set_option_value(
        "formatexpr",
        "v:lua.require'organ.format'.formatexpr()",
        { buf = bufnr }
      )
    end)
  end
  if (cfg.emphasis or {}).enabled then
    pcall(function()
      setlocal("conceallevel", 2)
    end)
  end

  -- Hide leading stars (Emacs `org-hide-leading-stars`). Off by default
  -- because it changes the visual structure; opt in via stars.hide=true.
  if (cfg.stars or {}).hide then
    require("organ.stars").attach(bufnr)
  end

  -- org-modern visual upgrades (bullets, block frames, pills). Each
  -- stage is independently opt-in via `modern.{bullets,blocks,pills}`.
  if (cfg.modern or {}).bullets or (cfg.modern or {}).blocks or (cfg.modern or {}).pills then
    require("organ.modern").attach(bufnr)
  end

  -- omnifunc fallback for users without blink.cmp / nvim-cmp.  Only
  -- set if the buffer doesn't already have one — we don't want to
  -- clobber user-supplied or LSP-attached omnifuncs.  Vim's built-in
  -- `<C-x><C-o>` then offers the link / id / file / property
  -- completions our cmp / blink sources expose.
  if (cfg.complete or {}).enabled ~= false then
    local existing = vim.api.nvim_get_option_value("omnifunc", { buf = bufnr })
    if existing == nil or existing == "" then
      vim.api.nvim_set_option_value(
        "omnifunc",
        "v:lua.require'organ.complete'.omnifunc",
        { buf = bufnr }
      )
    end
  end
end

return M
