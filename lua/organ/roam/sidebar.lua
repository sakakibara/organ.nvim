-- Persistent vertical-split roam sidebar (Emacs `org-roam-buffer-toggle`).
--
-- One sidebar per tabpage.  Each tab keeps its own bufnr / winid /
-- pin state / last-resized width — opening from a different tab gives
-- you a fresh sidebar there, not a teleport of the existing one.
--
-- Closing the sidebar window by any means (`:close`, `<C-w>q`, the
-- `q` keymap, M.close()) tears down the per-tab state and autocmds.
--
-- Renders share the pipeline with `:Org backlinks` (one-shot buffer)
-- but install our own jump keymaps so `<CR>`/`gs`/`gv` open in the
-- user's main editing window instead of replacing the sidebar.

local M = {}

-- Sentinel distinct from any real id (and from nil) so the first
-- render after open() always fires, even if the cursor is over an
-- id-less area.
local UNSET = {}

-- Per-tab state map.  Key is the tabpage handle returned by
-- `nvim_get_current_tabpage()`.  Each value is the singleton table
-- the previous singleton-version used.
local tabs = {}

local function fresh_state()
  return {
    bufnr = nil,
    winid = nil,
    target_winid = nil,
    current_id = UNSET,
    augroup = nil,
    pinned = false,
    last_width = nil, -- last interactively-resized width, persists across close/reopen
  }
end

local function tab_state(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local s = tabs[tab]
  if not s then
    s = fresh_state()
    tabs[tab] = s
  end
  return s, tab
end

local function get_cfg()
  local ok, organ = pcall(require, "organ")
  if not ok then
    return {}
  end
  return (organ.config.roam or {}).sidebar or {}
end

-- Resolve `width`: integer columns OR a "N%" string of total `&columns`.
-- A previously-resized width on this tab takes precedence so reopens
-- don't snap back to the configured default.
local function resolved_width(state)
  if state and state.last_width and state.last_width > 0 then
    return state.last_width
  end
  local raw = get_cfg().width or 50
  if type(raw) == "string" then
    local pct = raw:match("^(%d+)%%$")
    if pct then
      return math.max(20, math.floor(vim.o.columns * tonumber(pct) / 100))
    end
    return tonumber(raw) or 50
  end
  return raw
end

local function side_split_cmd()
  local pos = (get_cfg().position or "right"):lower()
  return pos == "left" and "topleft" or "botright"
end

-- Read the :ID: of the headline at cursor in `bufnr` (or, failing
-- that, the file-level :ID: in the leading PROPERTIES drawer — the
-- shape org-roam uses for its node files).
local function id_for_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not bufnr or bufnr < 0 or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return nil
  end
  local line = vim.fn.line(".")
  local ok, entries = pcall(require("organ.property").list, bufnr, line)
  if ok and entries then
    for _, e in ipairs(entries) do
      if e.key == "ID" then
        return e.value
      end
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 80, false)
  local in_drawer = false
  for _, l in ipairs(lines) do
    local trimmed = l:match("^%s*(.-)%s*$")
    if trimmed == ":PROPERTIES:" then
      in_drawer = true
    elseif trimmed == ":END:" then
      in_drawer = false
    elseif in_drawer then
      local v = trimmed:match("^:ID:%s*(%S+)")
      if v then
        return v
      end
    elseif trimmed:match("^%*") then
      break
    end
  end
  return nil
end

local function is_open(state)
  return state.winid and vim.api.nvim_win_is_valid(state.winid)
end

local function buf_valid(state)
  return state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)
end

-- Find a window suitable for landing jumps in.  Prefers the
-- previously-recorded target, falls back to any non-sidebar
-- non-floating window in the current tab, and as a last resort opens
-- a new vertical split to the LEFT of the sidebar.
local function ensure_target_win(state)
  if state.target_winid and vim.api.nvim_win_is_valid(state.target_winid) then
    return state.target_winid
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= state.winid and vim.api.nvim_win_get_config(w).relative == "" then
      state.target_winid = w
      return w
    end
  end
  vim.api.nvim_set_current_win(state.winid)
  vim.cmd("leftabove vsplit")
  state.target_winid = vim.api.nvim_get_current_win()
  return state.target_winid
end

local function set_window_options(winid)
  local wo = vim.wo[winid]
  wo.number = false
  wo.relativenumber = false
  wo.wrap = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.cursorline = true
  wo.colorcolumn = ""
  wo.spell = false
  wo.list = false
  wo.winfixwidth = true
  wo.statuscolumn = ""
  wo.winhighlight = "Normal:NormalSB,SignColumn:NormalSB,EndOfBuffer:NormalSB"
end

-- Re-render the sidebar to show backlinks for `id`.  No-op when the
-- sidebar is closed, the id matches what's already shown, or pinned.
local function rerender_for(state, id)
  if not is_open(state) or state.pinned then
    return
  end
  if id == state.current_id then
    return
  end
  state.current_id = id
  if not buf_valid(state) then
    return
  end
  if not id then
    vim.bo[state.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "(no node id under cursor)" })
    vim.bo[state.bufnr].modifiable = false
    return
  end
  vim.b[state.bufnr].organ_backlinks = { id = id }
  pcall(require("organ.backlinks").refresh, state.bufnr)
end

-- Open the row's source in the sidebar's target window using
-- `cmd_word` (`edit` / `split` / `vsplit`).  Drops the sidebar's
-- edit context so the sidebar itself isn't replaced or reshaped.
local function jump_in_target(state, cmd_word)
  if not buf_valid(state) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(state.winid)[1]
  local s = vim.b[state.bufnr].organ_backlinks or {}
  local r = (s.line_index or {})[lnum]
  if not r or not r.source_headline then
    return
  end
  local twin = ensure_target_win(state)
  vim.api.nvim_set_current_win(twin)
  vim.cmd(cmd_word .. " " .. vim.fn.fnameescape(r.source_headline.file_path))
  pcall(vim.api.nvim_win_set_cursor, 0, { (r.source_headline.line_start or 0) + 1, 0 })
end

local function install_sidebar_keymaps(state)
  local function map(lhs, fn, desc)
    vim.api.nvim_buf_set_keymap(state.bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      desc = desc,
      callback = fn,
    })
  end
  map("<CR>", function()
    jump_in_target(state, "edit")
  end, "jump to source in main window")
  map("gs", function()
    jump_in_target(state, "split")
  end, "open source in horizontal split")
  map("gv", function()
    jump_in_target(state, "vsplit")
  end, "open source in vertical split")
  map("r", function()
    state.current_id = nil
    rerender_for(
      state,
      id_for_cursor(state.target_winid and vim.api.nvim_win_get_buf(state.target_winid))
    )
  end, "refresh")
  map("p", function()
    M.toggle_pin()
  end, "toggle pin (freeze on current node)")
  map("q", function()
    M.close()
  end, "close roam sidebar")
end

local function ensure_augroup(state, tab)
  if state.augroup then
    return
  end
  state.augroup =
    vim.api.nvim_create_augroup("organ_roam_sidebar_tab_" .. tostring(tab), { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = state.augroup,
    callback = function(ev)
      -- Tab-local: only react when the event fires in the SAME tab
      -- this sidebar lives in.  Cursor moves in other tabs leave us
      -- alone.
      if vim.api.nvim_get_current_tabpage() ~= tab then
        return
      end
      if not is_open(state) then
        return
      end
      if ev.buf == state.bufnr then
        return
      end
      local win = vim.api.nvim_get_current_win()
      if win ~= state.winid and vim.api.nvim_win_get_config(win).relative == "" then
        state.target_winid = win
      end
      rerender_for(state, id_for_cursor(ev.buf))
    end,
  })
  -- Persist user-driven width changes so close + reopen restores them.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = state.augroup,
    callback = function()
      if not is_open(state) then
        return
      end
      local w = vim.api.nvim_win_get_width(state.winid)
      if w and w > 0 then
        state.last_width = w
      end
    end,
  })
  -- Tear down when the sidebar window closes by any means.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed and closed == state.winid then
        vim.schedule(function()
          M.close(tab)
        end)
      end
    end,
  })
  -- Drop per-tab state when the tab itself goes away.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = state.augroup,
    callback = function(ev)
      local tabnr = tonumber(ev.file)
      -- TabClosed gives a tab NUMBER (1-based index at close time),
      -- not a handle, so we can't directly compare.  Walk our tabs
      -- map and forget any handle that's no longer valid.
      for tab_handle, _ in pairs(tabs) do
        if not vim.api.nvim_tabpage_is_valid(tab_handle) then
          tabs[tab_handle] = nil
        end
      end
      local _ = tabnr
    end,
  })
end

-- Open (or focus) the sidebar in the CURRENT tab.
function M.open()
  local state, tab = tab_state()
  if is_open(state) then
    pcall(vim.api.nvim_set_current_win, state.winid)
    return
  end
  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_get_current_buf()

  vim.cmd(side_split_cmd() .. " " .. resolved_width(state) .. "vsplit")
  state.winid = vim.api.nvim_get_current_win()
  state.target_winid = origin_win

  local target_id = id_for_cursor(origin_buf)
  state.current_id = UNSET

  state.bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(
    state.bufnr,
    "organ-roam-sidebar://" .. tostring(tab) .. "/" .. tostring(state.bufnr)
  )
  vim.bo[state.bufnr].filetype = "organ-backlinks"
  vim.bo[state.bufnr].buftype = "nofile"
  vim.bo[state.bufnr].swapfile = false
  vim.bo[state.bufnr].buflisted = false
  vim.api.nvim_win_set_buf(state.winid, state.bufnr)
  set_window_options(state.winid)

  install_sidebar_keymaps(state)
  pcall(function()
    require("organ.ui").set_winbar(state.winid, {
      { "<CR>", "jump" },
      { "gs", "split" },
      { "gv", "vsplit" },
      { "r", "refresh" },
      { "p", "pin" },
      { "q", "close" },
    }, { title = "Roam sidebar" })
  end)

  -- Indexed-events listener so a write elsewhere refreshes the
  -- sidebar.  Debounced so a burst of writes collapses into one
  -- refresh.  Per-sidebar (closure captures `state`) so multiple
  -- tab sidebars don't interfere.
  do
    local events = require("organ.events")
    local cfg = (require("organ").config.roam or {}).sidebar or {}
    local debounce_ms = cfg.refresh_debounce_ms or 300
    local timer
    local listener = function(payload)
      if not buf_valid(state) then
        return
      end
      if payload and payload.skipped then
        return
      end
      if timer then
        pcall(function()
          timer:stop()
          timer:close()
        end)
      end
      local t = vim.loop.new_timer()
      timer = t
      t:start(
        debounce_ms,
        0,
        vim.schedule_wrap(function()
          if t:is_closing() then
            return
          end
          t:stop()
          t:close()
          if timer == t then
            timer = nil
          end
          if buf_valid(state) then
            pcall(require("organ.backlinks").refresh, state.bufnr)
          end
        end)
      )
    end
    events.on("indexed", listener)
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = state.bufnr,
      once = true,
      callback = function()
        events.off("indexed", listener)
        if timer then
          pcall(function()
            timer:stop()
            timer:close()
          end)
        end
      end,
    })
  end

  ensure_augroup(state, tab)
  rerender_for(state, target_id)
end

-- Close the sidebar in `tab` (defaults to current).  Idempotent.
function M.close(tab)
  local state
  state, tab = tab_state(tab)
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  if is_open(state) then
    pcall(vim.api.nvim_win_close, state.winid, true)
  end
  if buf_valid(state) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
  -- Preserve last_width across close/reopen; reset everything else.
  local saved_width = state.last_width
  tabs[tab] = fresh_state()
  tabs[tab].last_width = saved_width
end

function M.toggle()
  local state = tab_state()
  if is_open(state) then
    M.close()
  else
    M.open()
  end
end

-- Freeze / unfreeze the cursor-follow behavior on the current tab's
-- sidebar.
function M.toggle_pin()
  local state = tab_state()
  state.pinned = not state.pinned
  if buf_valid(state) then
    require("organ.notify").info(
      state.pinned and "roam sidebar: pinned" or "roam sidebar: following cursor"
    )
  end
end

-- Test / introspection helpers.  `_state()` returns the current
-- tab's state; `_tabs` is the full per-tab map.
function M._state(tab)
  return (tab_state(tab))
end
M._tabs = tabs

return M
