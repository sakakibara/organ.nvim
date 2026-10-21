-- Fold visibility anchored to the text.  Vim's expr folds have no
-- identity: open/closed state follows line positions, so an edit can hand
-- one heading's closed state to another or open a new fold closed.  This
-- module keeps, per window and buffer, the set of collapsed folds as
-- extmarks at their start lines (they move with the text, become invalid
-- when it is deleted and come back with undo), records the user's fold
-- actions into them, and after every edit puts Vim's folds back in line
-- with them.
--
--   record(winid)      read the window's closed folds into its marks
--   reconcile(bufnr)   make every window's folds match its marks
--   close(bufnr, line) mark a fold closed in every window (organ-created
--                      drawers start folded)

local M = {}

local NS = vim.api.nvim_create_namespace("organ_fold_marks")
M.NS = NS

local EXPR = "v:lua.require'organ.fold'.foldexpr(v:lnum)"

-- winid -> bufnr -> { marks = { [id] = true }, cursor_hidden = bool }
local wins = {}
-- bufnr -> true while an edit waits for its reconcile
local pending = {}
-- bufnr -> true when a pending edit was made in Insert mode
local insert_edit = {}
-- bufnr -> true while a fallback reconcile is scheduled
local scheduled = {}

M._wins, M._pending = wins, pending

local function in_scope(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local function opt(name)
    return vim.api.nvim_get_option_value(name, { win = winid })
  end
  return vim.bo[bufnr].filetype == "org"
    and opt("foldenable")
    and opt("foldmethod") == "expr"
    and opt("foldexpr") == EXPR
end

local function win_state(winid, bufnr)
  wins[winid] = wins[winid] or {}
  local st = wins[winid][bufnr]
  if not st then
    st = { marks = {}, cursor_hidden = false }
    wins[winid][bufnr] = st
  end
  return st
end

-- Fold start lines of the buffer, each with its fold level, from the
-- foldexpr cache for the current changedtick.
local function fold_starts(bufnr)
  local fold = require("organ.fold")
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cache = fold._foldcache[bufnr]
  if not cache or cache.tick ~= tick then
    vim.api.nvim_buf_call(bufnr, function()
      fold.foldexpr(1)
    end)
    cache = fold._foldcache[bufnr]
  end
  local starts = {}
  for lnum, v in pairs(cache and cache.levels or {}) do
    local n = v:match("^>(%d+)$")
    if n then
      starts[#starts + 1] = { line = lnum, level = tonumber(n) }
    end
  end
  return starts
end

-- Width of the opening token a mark must sit in to count for its line.
local function token_width(line)
  local stars = line:match("^(%*+%s)")
  if stars then
    return #stars
  end
  local drawer = line:match("^(%s*:[%w_-]+:)")
  if drawer then
    return #drawer
  end
  local block = line:match("^(%s*#%+[bB][eE][gG][iI][nN]_)")
  return block and #block or 1
end

-- The window's counting marks by line: lnum -> list of mark ids.
local function mark_lines(bufnr, st)
  local by_line = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })) do
    local id, row, col, details = m[1], m[2], m[3], m[4]
    if st.marks[id] and not details.invalid then
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      if col < token_width(line) then
        by_line[row + 1] = by_line[row + 1] or {}
        table.insert(by_line[row + 1], id)
      end
    end
  end
  return by_line
end

local function add_mark(bufnr, st, by_line, lnum)
  local id = vim.api.nvim_buf_set_extmark(bufnr, NS, lnum - 1, 0, {
    invalidate = true,
    undo_restore = true,
  })
  st.marks[id] = true
  by_line[lnum] = { id }
end

local function drop_marks(bufnr, st, by_line, lnum)
  for _, id in ipairs(by_line[lnum] or {}) do
    st.marks[id] = nil
    pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, id)
  end
  by_line[lnum] = nil
end

local function note_cursor(st)
  local c = vim.fn.line(".")
  local fc = vim.fn.foldclosed(c)
  st.cursor_hidden = fc ~= -1 and fc ~= c
end

-- Read the window's closed folds into its marks.  A fold hidden inside a
-- closed one is left as it is: Vim keeps its own state there, but
-- foldclosed() cannot read it.
function M.record(winid)
  winid = (winid == nil or winid == 0) and vim.api.nvim_get_current_win() or winid
  if not in_scope(winid) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  local st = win_state(winid, bufnr)
  local starts = fold_starts(bufnr)
  local by_line = mark_lines(bufnr, st)
  vim.api.nvim_win_call(winid, function()
    for _, s in ipairs(starts) do
      local fc = vim.fn.foldclosed(s.line)
      if fc == s.line then
        if not by_line[s.line] then
          add_mark(bufnr, st, by_line, s.line)
        end
      elseif fc == -1 and by_line[s.line] then
        drop_marks(bufnr, st, by_line, s.line)
      end
    end
    note_cursor(st)
  end)
end

-- Put one window's folds in line with its marks.
local function reconcile_win(winid, bufnr, opts)
  local st = win_state(winid, bufnr)
  local starts = fold_starts(bufnr)
  local by_line = mark_lines(bufnr, st)
  table.sort(starts, function(a, b)
    if a.level ~= b.level then
      return a.level < b.level
    end
    return a.line < b.line
  end)
  vim.api.nvim_win_call(winid, function()
    local view = vim.fn.winsaveview()
    if opts.reset_expr then
      local expr = vim.api.nvim_get_option_value("foldexpr", { win = winid })
      vim.api.nvim_set_option_value("foldexpr", expr, { win = winid, scope = "local" })
    end
    local cursor = vim.fn.line(".")
    local to_close = {}
    for _, s in ipairs(starts) do
      local fc = vim.fn.foldclosed(s.line)
      if fc == -1 or fc == s.line then
        if not by_line[s.line] then
          -- Two folds start on one line after a skipped heading level.
          for _ = 1, 8 do
            if vim.fn.foldclosed(s.line) ~= s.line then
              break
            end
            vim.cmd(("silent! %dfoldopen"):format(s.line))
          end
        elseif fc == -1 then
          to_close[#to_close + 1] = s
        end
      end
    end
    for i = #to_close, 1, -1 do
      local s = to_close[i]
      if vim.fn.foldclosed(s.line) == -1 then
        vim.cmd(("silent! %dfoldclose"):format(s.line))
      end
    end
    -- An edit never hides the line the cursor was on.
    if not st.cursor_hidden then
      for _ = 1, 64 do
        local fc = vim.fn.foldclosed(cursor)
        if fc == -1 or fc == cursor then
          break
        end
        vim.cmd(("silent! %dfoldopen"):format(fc))
        drop_marks(bufnr, st, by_line, fc)
      end
    end
    vim.fn.winrestview(view)
    note_cursor(st)
  end)
end

-- Make every in-scope window showing `bufnr` match its marks.
function M.reconcile(bufnr, opts)
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    pending[bufnr] = nil
    return
  end
  pending[bufnr] = nil
  local reset_expr = opts.insert_leave and insert_edit[bufnr]
  if opts.insert_leave then
    insert_edit[bufnr] = nil
  end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if in_scope(winid) then
      reconcile_win(winid, bufnr, { reset_expr = reset_expr })
    end
  end
end

local function insert_mode()
  return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
end

-- Run the reconcile an edit is waiting for, unless Insert mode in this
-- buffer defers it to InsertLeave.
function M.flush(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if pending[bufnr] and not (insert_mode() and bufnr == vim.api.nvim_get_current_buf()) then
    M.reconcile(bufnr)
  end
end

-- An edit happened in `bufnr` (organ.decoration's on_lines dispatch).
function M.on_lines(bufnr)
  pending[bufnr] = true
  if insert_mode() and bufnr == vim.api.nvim_get_current_buf() then
    insert_edit[bufnr] = true
  end
  if not scheduled[bufnr] then
    scheduled[bufnr] = true
    require("organ.errors").schedule("organ.fold.marks", function()
      scheduled[bufnr] = nil
      M.flush(bufnr)
    end)
  end
end

-- SafeState: run a waiting reconcile, else record what the user did with
-- folds since the last recording.
function M.on_safe_state()
  if insert_mode() then
    return
  end
  local seen = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].filetype == "org" and not seen[bufnr] and pending[bufnr] then
      seen[bufnr] = true
      M.reconcile(bufnr)
    end
  end
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if not pending[vim.api.nvim_win_get_buf(winid)] then
      M.record(winid)
    end
  end
end

-- Entering Insert mode opens the fold at the cursor; that is not the
-- user's fold action, so no snapshot may record it before InsertLeave.
function M.on_insert_enter()
  local c = vim.fn.line(".")
  if vim.fn.foldclosed(c) ~= -1 then
    pending[vim.api.nvim_get_current_buf()] = true
  end
end

function M.on_insert_leave(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if pending[bufnr] or insert_edit[bufnr] then
    M.reconcile(bufnr, { insert_leave = true })
  end
end

-- Mark the fold starting at `lnum` closed in every window showing the
-- buffer, and close it there.
function M.close(bufnr, lnum)
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if in_scope(winid) then
      local st = win_state(winid, bufnr)
      local by_line = mark_lines(bufnr, st)
      if not by_line[lnum] then
        add_mark(bufnr, st, by_line, lnum)
      end
    end
  end
  pending[bufnr] = true
end

-- A new window takes the marks of the window it was split from, else of
-- the buffer's most recently used window.
function M.seed(winid, from)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)
  if wins[winid] and wins[winid][bufnr] then
    return
  end
  local src = from and wins[from] and wins[from][bufnr]
  if not src then
    for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
      if w ~= winid and wins[w] and wins[w][bufnr] then
        src = wins[w][bufnr]
        break
      end
    end
  end
  local st = win_state(winid, bufnr)
  if src then
    local by_line = {}
    for lnum in pairs(mark_lines(bufnr, src)) do
      add_mark(bufnr, st, by_line, lnum)
    end
  else
    M.record(winid)
  end
end

function M.forget_window(winid)
  local per = wins[winid]
  wins[winid] = nil
  for bufnr, st in pairs(per or {}) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for id in pairs(st.marks) do
        pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, id)
      end
    end
  end
end

function M.forget_buffer(bufnr)
  for _, per in pairs(wins) do
    per[bufnr] = nil
  end
  pending[bufnr], insert_edit[bufnr], scheduled[bufnr] = nil, nil, nil
end

-- Clear the buffer's marks in every window (a reload starts over).
function M.clear(bufnr)
  for _, per in pairs(wins) do
    per[bufnr] = nil
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

-- Vim's fold keys, wrapped so a fold changed in a burst with an edit
-- reaches the marks before the next edit's reconcile.
local KEYS = { "zc", "zo", "za", "zC", "zO", "zA", "zv", "zx", "zX", "zM", "zR", "zm", "zr" }

local function global_mapping(key, mode)
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if m.lhs == key then
      return m
    end
  end
end

-- Run fold key `key` as Vim would, then record the window's folds.  A
-- global mapping of the key that a plugin made after organ attached runs
-- instead, and the idle snapshot records its result.
function M.native(key, mode)
  local g = global_mapping(key, mode)
  if g then
    if g.callback then
      g.callback()
    else
      local rhs = vim.api.nvim_replace_termcodes(g.rhs or "", true, false, true)
      local remap = g.noremap == 0 and (g.rhs or ""):sub(1, #key) ~= key
      vim.api.nvim_feedkeys(rhs, remap and "m" or "n", false)
    end
    return
  end
  M.flush(vim.api.nvim_get_current_buf())
  local count = vim.v.count > 0 and tostring(vim.v.count) or ""
  vim.cmd("normal! " .. count .. key)
  M.record(0)
end

function M.map_keys(bufnr)
  if (require("organ.buf_config").read(bufnr, "fold") or {}).wrap_native_keys == false then
    return
  end
  for _, mode in ipairs({ "n", "x" }) do
    for _, key in ipairs(KEYS) do
      if vim.fn.maparg(key, mode) == "" then
        vim.keymap.set(mode, key, function()
          M.native(key, mode)
        end, {
          buffer = bufnr,
          desc = "Fold " .. key .. " (kept through edits)",
        })
      end
    end
  end
end

-- Attach the buffer's edit and Insert-mode hooks; idempotent.
local attached = {}
function M.attach(bufnr)
  if attached[bufnr] then
    return
  end
  attached[bufnr] = true
  M.map_keys(bufnr)
  local group = vim.api.nvim_create_augroup("organ_fold_marks_" .. bufnr, { clear = true })
  local autocmd = require("organ.errors").autocmd
  autocmd("InsertEnter", { group = group, buffer = bufnr, callback = M.on_insert_enter })
  autocmd("InsertLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.on_insert_leave(bufnr)
    end,
  })
  autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })
end

-- Undo `attach` (the buffer is no longer org, or is wiped); the
-- ftplugin teardown removes the key wrappers.
function M.detach(bufnr)
  attached[bufnr] = nil
  M.forget_buffer(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "organ_fold_marks_" .. bufnr)
end

require("organ.decoration").register({
  name = "fold_marks",
  ns = vim.api.nvim_create_namespace("organ_fold_marks_dispatch"),
  enabled = function(bufnr)
    return attached[bufnr] == true
  end,
  on_lines_only = function(bufnr)
    M.on_lines(bufnr)
  end,
})

local group = vim.api.nvim_create_augroup("organ_fold_marks", { clear = true })
require("organ.errors").autocmd("SafeState", { group = group, callback = M.on_safe_state })
require("organ.errors").autocmd("WinNew", {
  group = group,
  callback = function()
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    M.seed(vim.api.nvim_get_current_win(), prev ~= 0 and prev or nil)
  end,
})
require("organ.errors").autocmd("WinClosed", {
  group = group,
  callback = function(args)
    local winid = tonumber(args.match)
    if winid then
      M.forget_window(winid)
    end
  end,
})

return M
