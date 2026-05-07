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
  map(km_todo.cycle, function()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local err = require("organ.todo").cycle(bufnr, line)
    if err then
      require("organ.notify").error(err)
    end
  end, "Cycle TODO state")
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
  end, "Pick TODO state")

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
  -- `foldtext` and `statuscolumn` are NOT set by default.  Wire them
  -- via your config (see |organ-config-fold-foldtext| / README
  -- "Foldtext" / "Statuscolumn").  Opt-in auto-apply is available
  -- via `fold.auto_foldtext = true` / `fold.auto_statuscolumn = true`
  -- for users who don't want to write Lua -- when set, organ writes
  -- those win-local options here using a flat `v:lua.<name>()` form
  -- (avoids the nvim TUI option-eval bug with chained `v:lua.require`
  -- calls).
  local cfg_fold_top = cfg.fold or {}
  local function apply_fold_window_opts()
    pcall(function()
      vim.api.nvim_set_option_value("foldmethod", "expr", { win = 0 })
      vim.api.nvim_set_option_value(
        "foldexpr",
        "v:lua.require'organ.fold'.foldexpr(v:lnum)",
        { win = 0 }
      )
      vim.api.nvim_set_option_value("foldenable", true, { win = 0 })
      -- `foldminlines = 0` lets the foldexpr's body folds (often a single
      -- line under a heading) actually close — the default of 1 silently
      -- drops 1-line folds that sit between adjacent transitions.
      vim.api.nvim_set_option_value("foldminlines", 0, { win = 0 })
      if cfg_fold_top.auto_foldtext == true then
        vim.api.nvim_set_option_value("foldtext", "v:lua._organ_foldtext()", { win = 0 })
      end
      if cfg_fold_top.auto_statuscolumn == true then
        vim.api.nvim_set_option_value("statuscolumn", "%!v:lua._organ_statuscolumn()", { win = 0 })
      end
      -- Remap the per-window Folded highlight to OrgFolded (bg = NONE)
      -- so folded heading lines blend with Normal's background.  The
      -- foldtext segments keep their natural foreground (TODO, title,
      -- tags) on top.  Append to whatever the user already had set in
      -- winhighlight rather than clobber it.
      local prev_wh = vim.api.nvim_get_option_value("winhighlight", { win = 0 })
      if not prev_wh:find("Folded:") then
        local new_wh = (prev_wh == "" and "Folded:OrgFolded") or (prev_wh .. ",Folded:OrgFolded")
        vim.api.nvim_set_option_value("winhighlight", new_wh, { win = 0 })
      end
    end)
  end
  apply_fold_window_opts()
  -- foldlevel only on the initial attach -- BufWinEnter shouldn't
  -- reset it back to 99 every time the user re-enters the window
  -- (would override <S-Tab> state).
  pcall(vim.api.nvim_set_option_value, "foldlevel", 99, { win = 0 })
  local fold_win_group = vim.api.nvim_create_augroup("organ_foldwin_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = fold_win_group,
    buffer = bufnr,
    callback = apply_fold_window_opts,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = fold_win_group,
    buffer = bufnr,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, fold_win_group)
    end,
  })

  -- Drawers start collapsed (Emacs default). Defer one tick so the TS
  -- parser + foldexpr have populated before we try to close ranges.
  -- Opt-out: cfg.fold.close_drawers_on_open = false.
  if (cfg.fold or {}).close_drawers_on_open ~= false then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        require("organ.fold").close_all_drawers(bufnr)
      end
    end)
  end

  -- Initial outline fold state (Emacs `org-startup-folded`).  Honor
  -- a buffer-local `#+STARTUP:` override (overview/content/showall/
  -- showeverything/fold/nofold) when present, else fall back to the
  -- global `startup.folded` config.
  --
  -- Scratch-style org buffers (capture float, etc.) opt out via
  -- `b:organ_no_startup_fold = true` so a 1-2 line entry isn't
  -- folded into a single headline-only line.
  if not vim.b[bufnr].organ_no_startup_fold then
    do
      local folded = (cfg.startup or {}).folded
      -- Scan the first 50 lines for #+STARTUP: directives.
      local lines = vim.api.nvim_buf_get_lines(
        bufnr,
        0,
        math.min(50, vim.api.nvim_buf_line_count(bufnr)),
        false
      )
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
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        pcall(function()
          -- Compute the deepest heading depth in the buffer. Used by
          -- the `content` state ("all headings visible, no body") to
          -- pick the right foldlevel for files of varying depth.
          local function max_heading_depth()
            local deepest = 0
            local n = vim.api.nvim_buf_line_count(bufnr)
            local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, n, false)
            for _, l in ipairs(buf_lines) do
              local stars = l:match("^(%*+)%s")
              if stars and #stars > deepest then
                deepest = #stars
              end
            end
            return deepest
          end
          -- Resolve the winid that holds bufnr at schedule-fire time.
          -- nvim_buf_call doesn't switch windows, so `win = 0` would
          -- target whatever window is current then -- if a different
          -- buffer (e.g. a capture float) is current, foldlevel=1
          -- lands on the wrong window.  Skip the fold-state push when
          -- bufnr isn't on screen anywhere.
          local target_winid = vim.fn.bufwinid(bufnr)
          if target_winid <= 0 then
            return
          end
          if folded == "overview" then
            pcall(vim.api.nvim_set_option_value, "foldlevel", 1, { win = target_winid })
          elseif folded == "content" then
            local depth = max_heading_depth()
            if depth < 1 then
              depth = 1
            end
            pcall(vim.api.nvim_set_option_value, "foldlevel", depth, { win = target_winid })
            -- Drawers (level depth+1) close as a side effect of the
            -- foldlevel; close_all_drawers above already collapsed
            -- them, no extra work needed.
          elseif folded == "showall" then
            vim.api.nvim_win_call(target_winid, function()
              vim.cmd("silent! normal! zR")
              -- zR re-opens drawers we collapsed above; restore them
              -- so `showall` matches Emacs (drawers hidden by default).
              require("organ.fold").close_all_drawers(bufnr)
            end)
          elseif folded == "showeverything" then
            vim.api.nvim_win_call(target_winid, function()
              vim.cmd("silent! normal! zR")
              -- showeverything is the one mode that opens drawers too.
            end)
          end
        end)
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
        require("organ.complete").maybe_open(bufnr)
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

  -- Inline emphasis + link concealment (Emacs `org-hide-emphasis-
  -- markers` + `org-link-descriptive`).  The walker is ALWAYS
  -- attached so the conceal extmarks are placed; they have no
  -- visual effect at `conceallevel = 0`, but the moment the user
  -- (or the `emphasis.enabled = true` shortcut) sets
  -- `conceallevel = 2`, marks render immediately — no manual
  -- `:Org emphasis toggle` needed.
  pcall(function()
    require("organ.conceal").attach(bufnr)
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
      vim.api.nvim_set_option_value("conceallevel", 2, { win = 0 })
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
