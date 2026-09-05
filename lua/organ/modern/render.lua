-- Persistent-extmark render engine for modern mode.
--
-- Neovim's decoration-provider ephemeral extmarks render overlay / eol /
-- conceal / hl_group but SILENTLY DROP inline virt_text. The rich modern
-- design needs inline virt_text for every width-adding element (rounded
-- pill caps, a calendar glyph that shifts its date, block-body padding), so
-- those elements cannot use the ephemeral provider. This engine places
-- NON-ephemeral extmarks -- which do render inline -- and refreshes them
-- over the visible range on edit / scroll / colorscheme.
--
-- Element renderers register a `render(bufnr, top, bot)` (0-based rows, bot
-- exclusive) and place marks into this module's namespace via the shared
-- badge / glyph primitives. They do NOT register decoration providers.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_render")
M.ns = NS

-- name -> render(bufnr, top, bot)
local renderers = {}

-- Post-render hooks: run once per refresh, AFTER every element renderer.
-- The right-align composer (layout.lua) flushes here so all elements have
-- contributed their segments before the single right_align mark is placed.
local after_hooks = {}

function M.after(fn)
  after_hooks[#after_hooks + 1] = fn
end

-- bufnr -> augroup id (attached buffers)
local groups = {}
-- bufnr -> debounce timer
local timers = {}
-- bufnr -> row last left undecorated for the cursor
local last_reveal = {}
-- Most engine elements conceal their raw tokens (checkboxes, dates,
-- priority, ...), which only hide at conceallevel >= 2, so the engine
-- claims the level on attach and lets go on detach.  The claim is shared
-- with organ's other conceal consumers (see organ.conceal).
local function raise_conceallevel(bufnr)
  require("organ.conceal").request_level_for_buf(bufnr, "modern")
end

local function restore_conceallevel(bufnr)
  require("organ.conceal").release_level_for_buf(bufnr, "modern")
end

function M.register(name, fn)
  renderers[name] = fn
end

-- Visible [top, bot) row range (0-based, bot exclusive) of the window
-- showing `bufnr`, or nil if it isn't displayed.
local function visible_range(bufnr)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    win = vim.fn.bufwinid(bufnr)
    if win == -1 then
      return nil
    end
  end
  local top = math.max(0, vim.fn.line("w0", win) - 1)
  local bot = vim.fn.line("w$", win) -- 1-based last visible == 0-based exclusive bound
  return top, bot
end

-- 0-based row whose decorations must be dropped so the raw text shows
-- under the cursor, or nil.  `modern.concealcursor` names the modes that
-- KEEP the decoration, like Vim's own `concealcursor`.
local function reveal_row(bufnr)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return nil
  end
  local keep = require("organ.buf_config").read(bufnr, "modern.concealcursor")
  if keep == nil then
    keep = "nv"
  end
  local mode = vim.api.nvim_get_mode().mode
  local key = mode:sub(1, 1)
  if key == "i" or key == "R" then
    key = "i"
  elseif key == "v" or key == "V" or key == "\22" then
    key = "v"
  elseif key == "c" then
    key = "c"
  else
    key = "n"
  end
  if keep:find(key, 1, true) then
    return nil
  end
  return vim.api.nvim_win_get_cursor(win)[1] - 1
end

local function do_refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local top, bot = visible_range(bufnr)
  if not top then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for _, fn in pairs(renderers) do
    pcall(fn, bufnr, top, bot)
  end
  for _, fn in ipairs(after_hooks) do
    pcall(fn, bufnr, top, bot)
  end
  local row = reveal_row(bufnr)
  if row and row >= 0 and row < vim.api.nvim_buf_line_count(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, row, row + 1)
  end
end

local function stop_timer(bufnr)
  local t = timers[bufnr]
  if t then
    t:stop()
    if not t:is_closing() then
      t:close()
    end
    timers[bufnr] = nil
  end
end

-- Refresh `bufnr` (default current). `immediate` renders synchronously;
-- otherwise a short debounce coalesces bursts (typing, scrolling).
function M.refresh(bufnr, immediate)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if immediate then
    stop_timer(bufnr)
    do_refresh(bufnr)
    return
  end
  stop_timer(bufnr)
  local t = vim.uv.new_timer()
  timers[bufnr] = t
  t:start(
    30,
    0,
    vim.schedule_wrap(function()
      stop_timer(bufnr)
      do_refresh(bufnr)
    end)
  )
end

-- bufnr -> set of element names attached to the engine.  The engine is
-- shared by every element, so it is torn down only when the last one
-- detaches.
local attached = {}

function M.attach(bufnr, name)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  attached[bufnr] = attached[bufnr] or {}
  if name then
    attached[bufnr][name] = true
  end
  raise_conceallevel(bufnr)
  if groups[bufnr] then
    M.refresh(bufnr, true)
    return
  end
  local g = vim.api.nvim_create_augroup("organ_modern_render_" .. bufnr, { clear = true })
  groups[bufnr] = g
  -- The scroll / resize autocmds below are window events, not buffer-scoped
  -- ones, so Neovim keeps them after the buffer is wiped.
  require("organ.buf_state").on_cleanup(bufnr, "modern_render", function(b)
    M.detach(b)
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    group = g,
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr)
    end,
  })
  -- Moving onto or off a decorated line changes which row is revealed;
  -- re-render only when that row actually changes.
  vim.api.nvim_create_autocmd(
    { "InsertEnter", "InsertLeave", "CursorMoved", "CursorMovedI", "ModeChanged" },
    {
      group = g,
      buffer = bufnr,
      callback = function()
        local row = reveal_row(bufnr)
        if row ~= last_reveal[bufnr] then
          last_reveal[bufnr] = row
          M.refresh(bufnr)
        end
      end,
    }
  )
  -- Scroll / resize are window events; refresh the current buffer if it is
  -- one we manage (buffer-local scoping is unreliable for WinScrolled).
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = g,
    callback = function()
      local cur = vim.api.nvim_get_current_buf()
      if groups[cur] then
        M.refresh(cur)
      end
    end,
  })
  M.refresh(bufnr, true)
end

-- Detach `name` (or every element when nil).  Other elements still
-- attached keep the engine; they are re-rendered without `name`.
function M.detach(bufnr, name)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local set = attached[bufnr]
  if name and set then
    set[name] = nil
    if next(set) then
      M.refresh(bufnr, true)
      return
    end
  end
  attached[bufnr] = nil
  if groups[bufnr] then
    pcall(vim.api.nvim_del_augroup_by_id, groups[bufnr])
    groups[bufnr] = nil
  end
  stop_timer(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  restore_conceallevel(bufnr)
end

-- The revealed row follows the FOCUSED window's cursor, so entering
-- another window or another buffer changes it even though nothing in the
-- managed buffer moved.  Global, not buffer-local: the buffer left
-- behind in a split needs its stale reveal dropped too.
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  group = vim.api.nvim_create_augroup("organ_modern_render_win", { clear = true }),
  callback = function()
    for bufnr in pairs(groups) do
      local row = reveal_row(bufnr)
      if row ~= last_reveal[bufnr] then
        last_reveal[bufnr] = row
        M.refresh(bufnr, true)
      end
    end
  end,
})

-- Recolor every managed buffer when the colorscheme changes (renderers
-- re-resolve their hl groups on each render).
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_render_colors", { clear = true }),
  callback = function()
    for bufnr in pairs(groups) do
      M.refresh(bufnr, true)
    end
  end,
})

-- Test-facing: render synchronously without autocmds/timers.
function M._render_now(bufnr)
  do_refresh(bufnr)
end

return M
