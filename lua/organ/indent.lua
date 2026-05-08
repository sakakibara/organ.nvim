-- Visual auto-indent (org-indent-mode equivalent) for organ.nvim.
--
-- Each line in a section of level N gets an inline virt-text prefix of
-- (N-1) * shift_per_level spaces, so nested content shifts right visually
-- without modifying the underlying buffer text.

local M = {}

M._ns = vim.api.nvim_create_namespace("organ_indent")
M._attached = {} -- { [bufnr] = augroup_id }
M._timers = {} -- { [bufnr] = uv_timer }
M._levels = {} -- { [bufnr] = { [line_1based] = level } } cached

local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return organ.config.indent or {}
end

local function compute_levels(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return nil
  end
  parser:parse(true)
  local tree = parser:parse()[1]
  if not tree then
    return nil
  end
  local root = tree:root()

  local n_lines = vim.api.nvim_buf_line_count(bufnr)
  local levels = {}

  local function heading_level(heading_node)
    local sr0 = heading_node:start()
    local first_line = vim.api.nvim_buf_get_lines(bufnr, sr0, sr0 + 1, false)[1] or ""
    local i = 0
    while first_line:byte(i + 1) == 42 do
      i = i + 1
    end
    return i > 0 and i or 1
  end

  local function visit(node, level)
    local start_row = node:start()
    local end_row
    do
      local r, _c = node:end_()
      end_row = r
    end

    for ln = start_row + 1, math.min(end_row, n_lines) do
      levels[ln] = level
    end

    for child in node:iter_children() do
      if child:type() == "headline" then
        visit(child, heading_level(child))
      end
    end
  end

  for child in root:iter_children() do
    if child:type() == "headline" then
      visit(child, heading_level(child))
    end
  end

  return levels
end

-- Place virt-text extmarks from a (1-based line → level) map. Used by
-- both refresh() (with freshly-computed levels) and apply_cached_levels()
-- (with the previous compute's levels — fast, no TS reparse).
local function apply_levels(bufnr, levels)
  local cfg = get_config()
  local shift = cfg.shift_per_level or 2
  local hl = cfg.hl_group or "Conceal"

  vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)
  if not levels then
    return
  end
  local n_lines = vim.api.nvim_buf_line_count(bufnr)
  for ln = 1, n_lines do
    local lvl = levels[ln]
    if lvl and lvl > 1 then
      local pad = string.rep(" ", (lvl - 1) * shift)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, ln - 1, 0, {
        virt_text = { { pad, hl } },
        virt_text_pos = "inline",
      })
    end
  end
end

-- Place inline virt-text extmarks for every line whose level > 1.
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local levels = compute_levels(bufnr)
  if not levels then
    return
  end
  M._levels[bufnr] = levels
  apply_levels(bufnr, levels)
end

-- Re-apply extmarks using the cached level map. Call this synchronously
-- on TextChanged so single-line edits (e.g. checkbox toggle) don't cause
-- the indent virt_text to vanish for the whole debounce window — the
-- toggled line was previously rendering as unindented for ~100ms after
-- the edit, which read as a flicker.
--
-- The cache becomes stale when the edit adds/removes a headline (level
-- ranges shift); the debounced refresh re-runs compute_levels and
-- replaces the cache shortly after.
local function apply_cached_levels(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  apply_levels(bufnr, M._levels[bufnr])
end

-- Debounce helper: cancel any pending timer for bufnr, start a new one.
local function debounced_refresh(bufnr)
  local cfg = get_config()
  local debounce = cfg.refresh_debounce_ms or 100
  if M._timers[bufnr] then
    pcall(function()
      M._timers[bufnr]:stop()
      M._timers[bufnr]:close()
    end)
  end
  local t = vim.uv.new_timer()
  M._timers[bufnr] = t
  t:start(
    debounce,
    0,
    vim.schedule_wrap(function()
      if t:is_closing() then
        return
      end
      pcall(function()
        t:stop()
        t:close()
      end)
      if M._timers[bufnr] == t then
        M._timers[bufnr] = nil
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.refresh(bufnr)
      end
    end)
  )
end

-- Attach autocmds that keep extmarks in sync with buffer edits.
function M.attach(bufnr)
  if M._attached[bufnr] then
    return
  end
  local group = vim.api.nvim_create_augroup("organ_indent_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufReadPost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      -- Two-phase: instant re-apply from cache (no flicker), then
      -- debounced full recompute (catches level changes from added /
      -- removed headlines).
      apply_cached_levels(bufnr)
      debounced_refresh(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function()
      M.detach(bufnr)
    end,
  })
  M._attached[bufnr] = group
  require("organ.debounce").apply_initial(bufnr, M.refresh)
end

-- Remove autocmds, stop any pending timer, and clear all extmarks.
function M.detach(bufnr)
  if not M._attached[bufnr] then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, M._attached[bufnr])
  M._attached[bufnr] = nil
  if M._timers[bufnr] then
    pcall(function()
      M._timers[bufnr]:stop()
      M._timers[bufnr]:close()
    end)
    M._timers[bufnr] = nil
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)
  end
end

function M.toggle(bufnr)
  if M._attached[bufnr] then
    M.detach(bufnr)
  else
    M.attach(bufnr)
  end
end

M.commands = {
  indent_mode = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      local arg = cmd and cmd.args or ""
      if arg == "" then
        M.toggle(bufnr)
      elseif arg:lower() == "on" then
        M.attach(bufnr)
      elseif arg:lower() == "off" then
        M.detach(bufnr)
      else
        require("organ.notify").error(":Org indent_mode takes no arg, 'on', or 'off'")
      end
    end,
    nargs = "?",
    complete = function()
      return { "on", "off" }
    end,
    desc = "Toggle / set visual auto-indent for the current buffer",
  },
}

return M
