-- Visual auto-indent (org-indent-mode equivalent) for organ.nvim.
--
-- Each line in a section of level N gets an inline virt-text prefix of
-- (N-1) * shift_per_level spaces, so nested content shifts right visually
-- without modifying the underlying buffer text.
--
-- Runs as an `organ.decoration` provider: `on_lines` rebuilds a per-
-- buffer row cache by walking the tree-sitter `headline` nodes to
-- determine the effective level for every line in each section.
-- `on_line` emits an ephemeral inline virt_text extmark for the visible
-- row.  The walk recurses through nested headlines, so a level change
-- at headline R cascades through all subordinate rows until the next
-- same-or-higher-level headline -- correctness of that cascade is why
-- the build forces a fresh parse (`parser:parse(true)`), and is also
-- why the rebuild on subsequent edits is debounced at 150ms.
--
-- Toggle is per-buffer (not filetype-global): `_attached[bufnr]` gates
-- the provider's `enabled` callback, so unrelated org buffers stay
-- untouched until the user runs `:Org indent_mode` or `cfg.indent.enabled`
-- triggers auto-attach in the ftplugin.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_indent")
M._ns = NS

-- Per-buffer attach state: `_attached[bufnr] = true` when the user has
-- opted this buffer into indent decoration.  The decoration provider
-- consults this in its `enabled` callback.
M._attached = {}

-- Per-buffer row cache: cache_by_buf[bufnr][row] = pad_string.  Rows
-- with level 1 (no indent) are absent.
local cache_by_buf = {}

local rebuild_timers = {}
-- Memory-probe test introspects per-buffer timer leaks via `_timers`;
-- expose the same table under both names so the assertion is meaningful.
M._timers = rebuild_timers
local REBUILD_DEBOUNCE_MS = 150

local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return organ.config.indent or {}
end

-- Walk tree-sitter `headline` nodes to assign an effective level to
-- every line in each section.  Recursion cascades the level change at
-- a sub-headline through its subordinate rows; the surrounding loop
-- over the parent's children means the next same-or-higher-level
-- headline resets the level for following rows.
local function compute_levels(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return nil
  end
  -- Force a fresh parse so the headline tree reflects the latest edit;
  -- the cascade-propagation correctness depends on accurate node
  -- ranges.  The 150ms rebuild debounce bounds per-keystroke cost.
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

-- Build the per-row cache: row -> pad string.  Rows with level 1 (no
-- indent) are absent.  Row keys are 0-based to match the decoration
-- provider's `on_line` row argument.
local function build_cache(bufnr)
  local rows = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return rows
  end
  local levels = compute_levels(bufnr)
  if not levels then
    return rows
  end
  local cfg = get_config()
  local shift = cfg.shift_per_level or 2
  local n_lines = vim.api.nvim_buf_line_count(bufnr)
  for ln = 1, n_lines do
    local lvl = levels[ln]
    if lvl and lvl > 1 then
      rows[ln - 1] = string.rep(" ", (lvl - 1) * shift)
    end
  end
  return rows
end

local function place_row(bufnr, row, pad, ephemeral)
  local cfg = get_config()
  local hl = cfg.hl_group or "Conceal"
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
    virt_text = { { pad, hl } },
    virt_text_pos = "inline",
    ephemeral = ephemeral or nil,
  })
end

local function cancel_rebuild_timer(bufnr)
  local t = rebuild_timers[bufnr]
  if not t then
    return
  end
  rebuild_timers[bufnr] = nil
  pcall(t.stop, t)
  pcall(t.close, t)
end

local function schedule_rebuild(bufnr)
  cancel_rebuild_timer(bufnr)
  local t = vim.uv.new_timer()
  if not t then
    -- Timer allocation failed (unlikely); fall back to a synchronous
    -- rebuild rather than silently dropping the update.
    cache_by_buf[bufnr] = build_cache(bufnr)
    return
  end
  rebuild_timers[bufnr] = t
  t:start(
    REBUILD_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      rebuild_timers[bufnr] = nil
      pcall(t.stop, t)
      pcall(t.close, t)
      if vim.api.nvim_buf_is_valid(bufnr) then
        cache_by_buf[bufnr] = build_cache(bufnr)
      end
    end)
  )
end

require("organ.decoration").register({
  name = "indent",
  ns = NS,
  enabled = function(bufnr)
    return M._attached[bufnr] == true
  end,
  on_lines = function(bufnr, _first, _last_old, _last_new)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    -- Full rebuild: tree-sitter's incremental parse keeps the cost
    -- bounded.  Range-bounded walks are a future optimization.  Initial
    -- population (cache empty) runs synchronously so the first frame
    -- after buffer open has correct decoration; subsequent edits
    -- debounce because the build forces `parser:parse(true)`.
    if cache_by_buf[bufnr] == nil then
      cache_by_buf[bufnr] = build_cache(bufnr)
      return
    end
    schedule_rebuild(bufnr)
  end,
  on_line = function(bufnr, _winid, row)
    local rows = cache_by_buf[bufnr]
    if not rows then
      return
    end
    local pad = rows[row]
    if not pad then
      return
    end
    place_row(bufnr, row, pad, true)
  end,
})

-- Rebuild the cache + place non-ephemeral extmarks for every cached
-- row.  Test-facing: assertions via `nvim_buf_get_extmarks` need real
-- (non-ephemeral) marks, which the on_line path doesn't produce.
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local rows = build_cache(bufnr)
  cache_by_buf[bufnr] = rows
  for row, pad in pairs(rows) do
    place_row(bufnr, row, pad, false)
  end
end

function M.attach(bufnr)
  if M._attached[bufnr] then
    return
  end
  M._attached[bufnr] = true
  pcall(function()
    require("organ.decoration").attach(bufnr)
  end)
  M.refresh(bufnr)
end

function M.detach(bufnr)
  if not M._attached[bufnr] then
    return
  end
  M._attached[bufnr] = nil
  cancel_rebuild_timer(bufnr)
  cache_by_buf[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
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
