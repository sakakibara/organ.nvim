-- Buffer-local agenda keymaps. install(bufnr, agenda) binds them,
-- honoring config.agenda.keymaps overrides (keymaps = false disables).

local M = {}

local vstate = require("organ.agenda.state")

-- Source-jump, preview, and split-open maps. These read the cursor row and
-- navigate to its source file without mutating agenda state.
local function install_navigation_maps(map, current_row)
  map("<CR>", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "jump")

  -- Preview the source headline + body in a floating window without
  -- leaving the agenda buffer. Press `q` or `<Esc>` (anything that
  -- closes the float) to dismiss. K is unbound in vim's normal-mode
  -- defaults for nofile buffers; override is non-conflicting.
  map("K", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path or not r.line_start then
      return
    end
    local target = vim.fn.bufadd(r.file_path)
    vim.fn.bufload(target)
    -- Slice from headline to subtree end.
    local structure = require("organ.structure")
    local hl = structure._find_containing_headline(target, (r.line_start or 0) + 1)
    if not hl then
      return
    end
    local subtree_end = structure._subtree_end(target, hl)
    local lines = vim.api.nvim_buf_get_lines(target, hl.line - 1, subtree_end, false)
    -- Width: longest line + small padding, capped to ~edge of window.
    local max_w = 0
    for _, l in ipairs(lines) do
      max_w = math.max(max_w, vim.fn.strdisplaywidth(l))
    end
    local width = math.min(math.max(max_w + 4, 40), math.floor(vim.o.columns * 0.8))
    local height = math.min(#lines, math.floor(vim.o.lines * 0.6))
    -- vim.lsp.util.open_floating_preview handles q / Esc dismissal +
    -- closes on cursor move. Set filetype=org so syntax highlights.
    local _, _ = vim.lsp.util.open_floating_preview(lines, "org", {
      width = width,
      height = height,
      border = "rounded",
    })
  end, "preview")

  -- Open in horizontal/vertical split. `gs` / `gv` -- single-finger
  -- two-key sequences in the vim "go" family (`g` prefix is the
  -- canonical "go to" namespace). Both have no-op vim defaults in a
  -- nomodifiable buffer (vim's `gs` sleeps, `gv` re-enters last
  -- visual selection -- neither does anything useful here).
  --
  -- We deliberately don't bind bare `o` or `v`: those shadow vim's
  -- normal-mode `o` (open new line) and `v` (visual-character mode)
  -- which users have hard-wired muscle memory for.
  map("gs", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("split " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "open_split")

  map("gv", function()
    local r = current_row()
    if not r then
      return
    end
    if not r.file_path then
      require("organ.notify").warn("agenda: this row has no source file")
      return
    end
    vim.cmd("vsplit " .. vim.fn.fnameescape(r.file_path))
    if r.line_start then
      vim.api.nvim_win_set_cursor(0, { r.line_start + 1, 0 })
    end
  end, "open_vsplit")
end

-- Refresh, view-mode toggles (entry-text / log mode), undo/redo of bulk
-- deletes, and buffer close.
local function install_refresh_maps(map, bufnr, agenda)
  map("r", function()
    agenda.refresh(bufnr)
  end, "refresh")

  -- `E` toggles entry-text mode (Emacs `org-agenda-entry-text-mode`):
  -- inject up to `agenda.entry_text.max_lines` body lines from each
  -- item's source headline as indented preview rows under the row.
  map("E", function()
    local state = vstate.get(bufnr)
    state.entry_text = not state.entry_text
    vstate.set(bufnr, state)
    agenda.refresh(bufnr)
  end, "toggle_entry_text")

  -- `l` toggles log mode (Emacs `org-agenda-log-mode`): inject CLOSED
  -- entries (and clock / state events when those land in the indexer)
  -- as additional rows on the day each event happened.  Set
  -- `agenda.log_mode.on_start = true` to default it on.
  map("l", function()
    local state = vstate.get(bufnr)
    state.log_mode = not state.log_mode
    vstate.set(bufnr, state)
    agenda.refresh(bufnr)
  end, "toggle_log_mode")

  -- Undo last destructive bulk op (delete, currently). Pops the
  -- per-buffer history stack and re-inserts each captured subtree at
  -- its original file:line position. Vim's native `u` is a no-op in
  -- this nofile non-modifiable buffer, so overriding it gives users
  -- the seamless "vim-native undo feel" they expect -- no
  -- :Org paste_subtree dance.
  map("u", function()
    local snap = agenda.undo_last_delete(bufnr)
    if not snap then
      require("organ.notify").info("agenda: nothing to undo")
      return
    end
    agenda.refresh(bufnr)
    require("organ.notify").info(("agenda: restored %d subtree(s)"):format(#snap))
  end, "undo_delete")

  -- Redo the last undone delete. Vim convention: <C-r>.
  map("<C-r>", function()
    local snap = agenda.redo_last_delete(bufnr)
    if not snap then
      require("organ.notify").info("agenda: nothing to redo")
      return
    end
    agenda.refresh(bufnr)
    require("organ.notify").info(("agenda: re-deleted %d subtree(s)"):format(#snap))
  end, "redo_delete")

  map("q", function()
    -- Snapshot any layout-restore command set up by agenda.open and run it
    -- AFTER the buffer is gone so the previous window arrangement
    -- comes back (Emacs `org-agenda-restore-windows-after-quit`).
    local restore = vim.b[bufnr].organ_agenda_restore_cmd
    vim.api.nvim_buf_delete(bufnr, { force = true })
    if restore and restore ~= "" then
      pcall(vim.cmd, restore)
    end
  end, "close")
end

-- In-buffer movement (next/prev item, block jumps), title filter, fold
-- toggle, and the keymap cheat-sheet.
local function install_movement_maps(map, bufnr, agenda)
  map("j", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = vstate.get(bufnr)
    local total = vim.api.nvim_buf_line_count(bufnr)
    for i = lnum + 1, total do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "next_item")

  map("k", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = vstate.get(bufnr)
    for i = lnum - 1, 1, -1 do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "prev_item")

  map("/", function()
    local input = vim.fn.input("filter title: ")
    local state = vstate.get(bufnr)
    local view = state.view or { blocks = {} }
    for _, block in ipairs(view.blocks) do
      block.title_match = input ~= "" and input or nil
    end
    state.view = view
    vstate.set(bufnr, state)
    agenda.refresh(bufnr)
  end, "filter")

  map("<Tab>", function()
    vim.cmd("normal! za")
  end, "fold")

  map("]]", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = vstate.get(bufnr)
    local starts = state.block_starts or {}
    local target
    for k in pairs(starts) do
      if k > lnum and (target == nil or k < target) then
        target = k
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
  end, "next_block")

  map("[[", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = vstate.get(bufnr)
    local starts = state.block_starts or {}
    local target
    for k in pairs(starts) do
      if k < lnum and (target == nil or k > target) then
        target = k
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
  end, "prev_block")

  map("g?", function()
    local help = {
      "organ.agenda keymaps",
      "  Navigation",
      "    <CR>  jump to source         gs / gv  split / vsplit",
      "    j / k  next/prev item        ]] / [[  next/prev block",
      "    <Tab>  toggle block fold     /        title filter",
      "  Period",
      "    f / b  next/prev             .        today",
      "    gd / gw  day/week view       gj       jump to date",
      "  Per-row edit",
      "    t  cycle TODO                T        TODO menu",
      "    s  schedule                  D        deadline",
      "    +  raise priority            -        lower priority",
      "    =  clear priority            gT       set tags",
      "    R  refile                    I / O    clock in/out",
      "    e  effort filter",
      "  Bulk",
      "    <Space>  mark + advance      gM       mark all toggle",
      "    gB       apply action menu",
      "    u        undo last delete    <C-r>    redo last undone",
      "  Misc",
      "    A   archive row                gA  show/hide archived",
      "    gC  open clock report          gR  toggle in-agenda clocktable",
      "    <M-CR>  new entry            r   refresh",
      "    q   close                    g?  this help",
    }
    vim.api.nvim_echo({ { table.concat(help, "\n"), "None" } }, true, {})
  end, "help")
end

-- Per-row TODO state changes (cycle / pick), priority raise/lower/clear,
-- and the date-jump prompt.
local function install_todo_priority_maps(map, bufnr, agenda, current_row, source_for)
  map("t", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local err = require("organ.todo").cycle(target, lnum)
    if err then
      require("organ.notify").error(err)
    end
  end, "todo_cycle")

  map("T", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    -- Use the SOURCE FILE's sequence (file-level `#+TODO:` directive
    -- wins over global config), matching Emacs's per-file behavior.
    local choices = { "(none)" }
    for _, k in ipairs(require("organ.todo").all_keywords()) do
      choices[#choices + 1] = k
    end
    -- If the row's source buffer is loaded, prefer its file-level
    -- directives over global; otherwise fall back to global keywords.
    if vim.api.nvim_buf_is_valid(target) then
      local seqs = require("organ.todo").effective_sequences(target)
      local seen, file_choices = {}, { "(none)" }
      for _, seq in ipairs(seqs) do
        for _, k in ipairs(seq) do
          if k ~= "|" and not seen[k] then
            seen[k] = true
            file_choices[#file_choices + 1] = k
          end
        end
      end
      if #file_choices > 1 then
        choices = file_choices
      end
    end
    vim.ui.select(choices, { prompt = "TODO state: " }, function(choice)
      if not choice then
        return
      end
      local state = choice == "(none)" and nil or choice
      local err = require("organ.todo").set(target, lnum, state)
      if err then
        require("organ.notify").error(err)
      end
    end)
  end, "todo_set")

  -- Priority: ^ raise, _ lower, $ clear (Emacs convention).
  -- Priority shortcuts -- `+` raise, `-` lower, `=` clear. Mnemonic:
  -- + = more, - = less, = = none. Avoids vim's `^`/`$` (line start/end
  -- navigation, useful even in fixed-format buffers).
  map("+", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").raise_priority(target, lnum)
    agenda.refresh(bufnr)
  end, "priority_raise")

  map("-", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").lower_priority(target, lnum)
    agenda.refresh(bufnr)
  end, "priority_lower")

  map("=", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.inline_edit").set_priority(target, lnum, nil)
    agenda.refresh(bufnr)
  end, "priority_clear")

  -- Jump to a specific date (Emacs `j` in org-agenda; we use `gj` since
  -- `j` is already bound to next-item-line).
  map("gj", function()
    vim.ui.input({ prompt = "Jump to date (YYYY-MM-DD or 'today', '+1w'…): " }, function(input)
      if not input or input == "" then
        return
      end
      local query = require("organ.query")
      local parsed = nil
      if query.parse_date then
        local ok, p = pcall(query.parse_date, input)
        if ok and p then
          parsed = p
        end
      end
      -- Fall back to literal pass-through when parse_date isn't available
      -- or doesn't recognise the input -- set_window will validate.
      parsed = parsed or input
      agenda.set_window(bufnr, parsed, parsed)
      agenda.refresh(bufnr)
    end)
  end, "jump_to_date")
end

-- Bulk selection + action menu (Emacs `m`/`u`/`*`/`B B`).
-- Marks are stored on buf_state.bulk_marked as { [src_id] = true }
-- and rendered as a sign in the agenda buffer's gutter. Action menu
-- (`B`) iterates marked rows and applies one of: state change,
-- schedule, deadline, refile, archive, delete-subtree.
local function install_bulk_maps(map, bufnr, agenda, current_row, source_for)
  -- Mark id: row.id when present; else file_path .. ":" .. line_start.
  local function row_mark_id(r)
    if not r then
      return nil
    end
    if r.id then
      return r.id
    end
    if r.file_path and r.line_start then
      return r.file_path .. ":" .. r.line_start
    end
    return nil
  end

  local SIGN_GROUP = "organ_agenda_bulk_" .. bufnr
  local SIGN_NAME = "OrganAgendaBulk"
  pcall(vim.fn.sign_define, SIGN_NAME, { text = "▎", texthl = "@organ.agenda.priority_A" })

  local function redraw_bulk_signs()
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
    local state = vstate.get(bufnr)
    local marked = state.bulk_marked or {}
    for lnum, r in pairs(state.line_index or {}) do
      local id = row_mark_id(r)
      if id and marked[id] then
        pcall(vim.fn.sign_place, 0, SIGN_GROUP, SIGN_NAME, bufnr, { lnum = lnum, priority = 10 })
      end
    end
  end

  -- <Space> toggles bulk mark on the cursor row + advances to next
  -- item. Space is unmapped in vim-default normal mode (it's <Right>
  -- as motion), so this is the cleanest single-key for bulk select
  -- without colliding with `*` (search-word) or `m` (set register).
  map("<Space>", function()
    local r = current_row()
    local id = row_mark_id(r)
    if id then
      local state = vstate.get(bufnr)
      state.bulk_marked = state.bulk_marked or {}
      local on = state.bulk_marked[id]
      state.bulk_marked[id] = (not on) and true or nil
      vstate.set(bufnr, state)
      redraw_bulk_signs()
    end
    -- Advance to the next item row.
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local total = vim.api.nvim_buf_line_count(bufnr)
    local state = vstate.get(bufnr)
    for i = lnum + 1, total do
      if (state.line_index or {})[i] then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end, "bulk_mark_toggle")

  -- gM toggles bulk mark for ALL visible rows. (gM is unbound in vim
  -- default; capital M alone moves to middle of window -- useful -- and
  -- `*` is search-word -- also useful -- so we use the g prefix.)
  map("gM", function()
    local state = vstate.get(bufnr)
    state.bulk_marked = state.bulk_marked or {}
    local any = next(state.bulk_marked) ~= nil
    if any then
      state.bulk_marked = {}
    else
      for _, r in pairs(state.line_index or {}) do
        local id = row_mark_id(r)
        if id then
          state.bulk_marked[id] = true
        end
      end
    end
    vstate.set(bufnr, state)
    redraw_bulk_signs()
  end, "bulk_mark_all")

  -- gB applies the action menu to every marked row. (vim's `B` is
  -- back-WORD which we keep available.) Iterates marked rows, prompts
  -- for action, applies.
  -- Resolves each marked id back to its source via the buffer's
  -- line_index (we look up live so cursor moves don't matter).
  map("gB", function()
    local state = vstate.get(bufnr)
    local marked = state.bulk_marked or {}
    local marked_rows = {}
    for _, r in pairs(state.line_index or {}) do
      local id = row_mark_id(r)
      if id and marked[id] then
        marked_rows[#marked_rows + 1] = r
      end
    end
    if #marked_rows == 0 then
      require("organ.notify").warn("agenda: no rows marked (press <Space> to mark)")
      return
    end
    local actions = {
      { "Set TODO state", "todo" },
      { "Schedule", "schedule" },
      { "Set deadline", "deadline" },
      { "Refile", "refile" },
      { "Archive subtree", "archive" },
      { "Delete subtree", "delete" },
    }
    local labels = {}
    for _, a in ipairs(actions) do
      labels[#labels + 1] = a[1]
    end
    vim.ui.select(
      labels,
      { prompt = ("Bulk (%d rows):"):format(#marked_rows) },
      function(choice, idx)
        if not choice then
          return
        end
        if not idx then
          for i, l in ipairs(labels) do
            if l == choice then
              idx = i
              break
            end
          end
        end
        if not idx then
          return
        end
        local kind = actions[idx][2]
        local apply
        if kind == "todo" then
          local cfg = require("organ.buf_config").read(nil, "todo") or {}
          local choices = { "(none)" }
          for _, k in ipairs(cfg.sequence or {}) do
            if k ~= "|" then
              choices[#choices + 1] = k
            end
          end
          vim.ui.select(choices, { prompt = "TODO state for all marked: " }, function(state_choice)
            if not state_choice then
              return
            end
            local new_state = state_choice == "(none)" and nil or state_choice
            for _, r in ipairs(marked_rows) do
              local target, lnum = source_for(r)
              if target then
                pcall(require("organ.todo").set, target, lnum, new_state)
              end
            end
            state.bulk_marked = {}
            vstate.set(bufnr, state)
            redraw_bulk_signs()
            agenda.refresh(bufnr)
          end)
          return
        elseif kind == "schedule" then
          apply = function(target, lnum)
            require("organ.schedule").set_schedule(target, lnum)
          end
        elseif kind == "deadline" then
          apply = function(target, lnum)
            require("organ.schedule").set_deadline(target, lnum)
          end
        elseif kind == "refile" then
          -- Bulk-refile is fiddly (one target, multiple sources) -- fall
          -- back to triggering the per-row refile picker for each marked
          -- row. The user picks a destination once per row.
          apply = function(target, lnum)
            local saved = vim.api.nvim_get_current_buf()
            vim.api.nvim_set_current_buf(target)
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            pcall(require("organ.refile").refile)
            pcall(vim.api.nvim_set_current_buf, saved)
          end
        elseif kind == "archive" then
          apply = function(target, lnum)
            require("organ.archive").archive_subtree(target, lnum)
          end
        elseif kind == "delete" then
          local confirm = vim.fn.confirm(
            ("Delete %d subtree(s)? Press `u` in this buffer to undo."):format(#marked_rows),
            "&Yes\n&No",
            2
          )
          if confirm ~= 1 then
            return
          end
          -- Resolve marked_rows to (target_buf, lnum) pairs and hand
          -- to agenda.bulk_delete_apply. The public function snapshots,
          -- cuts, and pushes to delete_history.
          local resolved = {}
          for _, r in ipairs(marked_rows) do
            local target, lnum = source_for(r)
            if target then
              resolved[#resolved + 1] = { _source_bufnr = target, _source_lnum = lnum }
            end
          end
          local snapshot = agenda.bulk_delete_apply(bufnr, resolved)
          state.bulk_marked = {}
          vstate.set(bufnr, state)
          redraw_bulk_signs()
          agenda.refresh(bufnr)
          require("organ.notify").info(("Deleted %d subtree(s). `u` to undo."):format(#snapshot))
          return
        end
        if apply then
          for _, r in ipairs(marked_rows) do
            local target, lnum = source_for(r)
            if target then
              pcall(apply, target, lnum)
            end
          end
          state.bulk_marked = {}
          vstate.set(bufnr, state)
          redraw_bulk_signs()
          agenda.refresh(bufnr)
        end
      end
    )
  end, "bulk_action")
end

-- Per-row edit / period / misc maps: tags, archive visibility + archive,
-- clock report toggles, new entry, schedule/deadline, clock in/out, refile,
-- period navigation, day/week views, and the effort filter.
local function install_edit_maps(map, bufnr, agenda, current_row, source_for)
  -- Set tags on row at cursor. Bound to `gT` (override vim's "previous
  -- tab" -- agenda buffers usually live in a single tab, and the
  -- alternative `:` would shadow vim's command-mode trigger which
  -- users press constantly). For users who DO want :tabprev, vim's
  -- `:tabprevious` command is always available.
  map("gT", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local cur = require("organ.tag_writer").read(target, lnum) or {}
    vim.ui.input(
      { prompt = "Tags (space- or colon-separated): ", default = table.concat(cur, " ") },
      function(input)
        if input == nil then
          return
        end
        local tags = {}
        for tok in input:gmatch("[^%s:]+") do
          tags[#tags + 1] = tok
        end
        require("organ.tag_writer").write(target, lnum, tags)
        agenda.refresh(bufnr)
      end
    )
  end, "set_tags")

  -- Toggle whether archived headlines are SHOWN in the agenda. Bound
  -- to `gA` so the user's vim `;` (repeat f/F/t/T) stays usable.
  -- Distinct from `A` below, which archives the row at cursor.
  map("gA", function()
    local state = vstate.get(bufnr)
    state.show_archived = not state.show_archived
    vstate.set(bufnr, state)
    require("organ.notify").info(
      "agenda: archived rows " .. (state.show_archived and "shown" or "hidden")
    )
    agenda.refresh(bufnr)
  end, "toggle_archived_visibility")

  -- Archive the source headline of the row at cursor (Emacs `$` in
  -- agenda -> `org-agenda-archive`). We use uppercase `A` because our
  -- `$` is bound to clear-priority and lowercase `a` is unbound and
  -- frequently typed by mistake.
  map("A", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    local err = require("organ.archive").archive_subtree(target, lnum)
    if err then
      require("organ.notify").error(tostring(err))
      return
    end
    require("organ.notify").info("archived")
    agenda.refresh(bufnr)
  end, "archive_row")

  -- Open clock report from agenda. `c` is unbound in vim default
  -- normal mode (the `c` family -- `cw`, `cc` -- are operator-pending,
  -- which still works because `c` alone waits for a motion. We
  -- override only the wait-for-motion case in this nofile buffer
  -- where text-changing motions are no-ops anyway.)
  map("gC", function()
    pcall(require("organ.clock").report)
  end, "clock_report")

  -- gR: toggle in-agenda clock-report mode (Emacs `R` in agenda buffer
  -- but R is taken by refile; use gR to mirror the "g-prefix for go-do"
  -- pattern). When on, the agenda renderer appends a clocktable showing
  -- clocked time for headlines visible in the current window. Toggle
  -- again to remove.
  map("gR", function()
    local state = vstate.get(bufnr)
    state.clock_report_mode = not state.clock_report_mode
    vstate.set(bufnr, state)
    require("organ.notify").info(
      "agenda: clock-report mode " .. (state.clock_report_mode and "ON" or "OFF")
    )
    agenda.refresh(bufnr)
  end, "toggle_clock_report")

  -- M-CR: add a new TODO heading. Prompts for title, then for target file
  -- (defaults to the current row's file or org_dir's first file).
  map("<M-CR>", function()
    local default_path
    local r = current_row()
    if r and r.file_path then
      default_path = r.file_path
    end
    if not default_path then
      local org_dir = require("organ.buf_config").read(nil, "org_dir")
      if org_dir and org_dir ~= "" then
        local fd = vim.uv.fs_scandir(org_dir)
        if fd then
          while true do
            local n, t = vim.uv.fs_scandir_next(fd)
            if not n then
              break
            end
            if t == "file" and n:match("%.org$") then
              default_path = org_dir .. "/" .. n
              break
            end
          end
        end
      end
    end
    vim.ui.input({ prompt = "New TODO: " }, function(title)
      if not title or title == "" then
        return
      end
      vim.ui.input({ prompt = "File: ", default = default_path or "" }, function(file)
        if not file or file == "" then
          return
        end
        local ok_path, why = agenda.add_entry_path_ok(file)
        if not ok_path then
          require("organ.notify").error("agenda add-entry: " .. why)
          return
        end
        -- Append a new top-level TODO heading at end of file.
        local lines = vim.fn.readfile(file)
        if lines == nil then
          lines = {}
        end
        if #lines > 0 and lines[#lines] ~= "" then
          lines[#lines + 1] = ""
        end
        lines[#lines + 1] = "* TODO " .. title
        vim.fn.writefile(lines, file)
        require("organ.notify").info("appended to " .. file)
        -- Re-index + refresh agenda.
        require("organ.queue").enqueue_interactive(file)
        vim.defer_fn(function()
          agenda.refresh(bufnr)
        end, 200)
      end)
    end)
  end, "add_entry")

  -- Schedule / deadline: reuse the calendar picker on the source headline.
  map("s", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.schedule").set_schedule(target, lnum)
  end, "schedule")

  map("D", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.schedule").set_deadline(target, lnum)
  end, "deadline")

  -- Clocking from agenda.
  map("I", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    require("organ.clock").start({ bufnr = target, line = lnum })
  end, "clock_in")

  map("O", function()
    require("organ.clock").stop({})
  end, "clock_out")

  -- Refile the source subtree: switch to source, position cursor, dispatch.
  map("R", function()
    local r = current_row()
    if not r then
      return
    end
    local target, lnum = source_for(r)
    if not target then
      return
    end
    vim.api.nvim_set_current_buf(target)
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    require("organ.refile").refile()
  end, "refile")

  -- Date navigation: shift the visible window forward/back by its own length;
  -- "." resets to today (range length preserved).
  map("f", function()
    agenda.shift_period(bufnr, 1)
    agenda.refresh(bufnr)
  end, "next_period")
  map("b", function()
    agenda.shift_period(bufnr, -1)
    agenda.refresh(bufnr)
  end, "prev_period")
  map(".", function()
    agenda.reset_today(bufnr)
    agenda.refresh(bufnr)
  end, "today")

  -- View-mode switches: 1-day / 7-day window starting today.
  -- View-window commands. Prefix `g` keeps them in the same family as
  -- `gs`/`gv` (open split/vsplit). The previous `vd`/`vw` bindings
  -- caused a 1-second timeoutlen wait on every bare `v` because vim had
  -- to disambiguate `v` (visual mode) vs `vd`/`vw` (these). With `gd`/`gw`
  -- the `v` key fires visual mode immediately.
  map("gd", function()
    agenda.set_window(bufnr, "today", "today")
    agenda.refresh(bufnr)
  end, "view_day")
  map("gw", function()
    agenda.set_window(bufnr, "today", "+6d")
    agenda.refresh(bufnr)
  end, "view_week")

  -- Effort filter. `e` prompts for a spec ("<30", "1:00..2:00", ">=60");
  -- empty input clears.
  map("e", function()
    vim.ui.input({ prompt = "Effort filter (e.g. <30, 1:00..2:00, >=1h): " }, function(input)
      if input == nil then
        return
      end
      local s = vstate.get(bufnr)
      s.effort_filter = input
      vstate.set(bufnr, s)
      agenda.refresh(bufnr)
    end)
  end, "effort_filter")
end

local function install(bufnr, agenda)
  local agenda_cfg = require("organ.buf_config").read(nil, "agenda") or {}
  -- Rule 2: keymaps = false disables all agenda bindings.
  if agenda_cfg.keymaps == false then
    return
  end
  local cfg = agenda_cfg.keymaps or {}

  local function map(default_lhs, rhs, desc)
    local lhs = cfg[desc] -- user may override via organ.config.agenda.keymaps[desc]
    if lhs == false then
      return
    end
    if lhs == nil then
      lhs = default_lhs
    end
    vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      desc = desc,
      callback = rhs,
    })
  end

  local function current_row()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local state = vstate.get(bufnr)
    return (state.line_index or {})[lnum]
  end

  -- Helper: load the source buffer + return the 1-based source line for a
  -- row. Returns nil + warns if the row has no editable source (synthetic
  -- diary_sexp rows, empty-state placeholders, etc. lack file_path /
  -- line_start). Without this guard, every t/T/s/D/I/R/<CR>/gs/gv keymap
  -- would crash with `attempt to perform arithmetic on field 'line_start'
  -- (a nil value)` on synthetic rows.
  local function source_for(r)
    if not r.file_path or not r.line_start then
      require("organ.notify").warn(
        "agenda: this row has no editable source (synthetic / placeholder)"
      )
      return nil, nil
    end
    local target = vim.fn.bufadd(r.file_path)
    vim.fn.bufload(target)
    return target, r.line_start + 1
  end

  install_navigation_maps(map, current_row)
  install_refresh_maps(map, bufnr, agenda)
  install_movement_maps(map, bufnr, agenda)
  install_todo_priority_maps(map, bufnr, agenda, current_row, source_for)
  install_bulk_maps(map, bufnr, agenda, current_row, source_for)
  install_edit_maps(map, bufnr, agenda, current_row, source_for)
end

M.install = install

return M
