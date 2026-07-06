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

-- bufnr -> augroup id (attached buffers)
local groups = {}
-- bufnr -> debounce timer
local timers = {}

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

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if groups[bufnr] then
    M.refresh(bufnr, true)
    return
  end
  local g = vim.api.nvim_create_augroup("organ_modern_render_" .. bufnr, { clear = true })
  groups[bufnr] = g
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    group = g,
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr)
    end,
  })
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

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if groups[bufnr] then
    pcall(vim.api.nvim_del_augroup_by_id, groups[bufnr])
    groups[bufnr] = nil
  end
  stop_timer(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

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
