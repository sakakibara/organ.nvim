-- Visual auto-indent (org-indent-mode equivalent) for organ.nvim.
--
-- Body rows of a level-N section get an inline virt-text prefix sized
-- so the first body byte renders at the title-text column of its
-- enclosing headline.  The heading line itself takes a pad of
-- (N-1) * shift_per_level when stars render as literal `*` characters,
-- and no pad when stars are visually replaced (modern bullets or
-- stars.hide), since those modes already convey level via their own
-- conceal-as-spaces treatment.
--
-- Runs as an `organ.decoration` provider: `on_win` walks the tree-sitter
-- `headline` nodes overlapping the visible window range and assigns an
-- effective level to every row in `[topline, botline]`, with the
-- cascade through nested headlines reset by each same-or-higher-level
-- sibling.  `on_line` reads the frame-local row map and emits an
-- ephemeral inline virt_text extmark for the current row.  The tree is
-- parsed once per buffer per redraw by organ.decoration and shared with
-- the other decoration providers.
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

-- Empty-table sentinel.  The memory-probe test asserts
-- `tablen(indent._timers) == 0` to catch per-buffer timer leaks; the
-- on_win design has no timers, but the assertion stays meaningful
-- because the table stays empty.
M._timers = {}

local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return organ.config.indent or {}
end

-- True when the headline's leading stars are visually replaced (modern
-- bullets cycling glyphs, or stars.hide concealing them as spaces).
-- Under either mode the rendered title sits at column L+2 already, so
-- the heading row needs no virt-text pad and the body must align with
-- the title (column L+2, i.e. body pad = L + 1).  `modern.bullets` may
-- be `true` or a config table; both are truthy.
local function stars_visually_hidden()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return false
  end
  local cfg = organ.config
  local modern = cfg.modern or {}
  if modern.bullets then
    return true
  end
  local stars = cfg.stars or {}
  if stars.hide == true then
    return true
  end
  return false
end

-- Frame-local row map: frame_map[row] = pad_string.  Reset at the
-- start of every on_win call; read by on_line for the same frame.
-- Rows at level 1 (no indent) are absent.
local frame_map = {}

local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not M._attached[bufnr] then
    return
  end
  -- Tree is parsed once per buffer per redraw by organ.decoration; we
  -- just query the cached tree here.
  local tree = require("organ.decoration").get_tree(bufnr)
  if not tree then
    return
  end
  local root = tree:root()
  local cfg = get_config()
  local shift = cfg.shift_per_level or 2
  local hide_stars = stars_visually_hidden()

  local function heading_level(heading_node)
    local sr0 = heading_node:start()
    local first_line = vim.api.nvim_buf_get_lines(bufnr, sr0, sr0 + 1, false)[1] or ""
    local i = 0
    while first_line:byte(i + 1) == 42 do
      i = i + 1
    end
    return i > 0 and i or 1
  end

  -- Walk the headline tree.  Parent visits BEFORE children, so a
  -- deeper nested heading overwrites the parent's heading_pad on its
  -- own row and the parent's body_pad on rows owned by the child.
  -- We only populate frame_map for rows in [topline, botline]; rows
  -- outside the visible range are skipped.  Tree-sitter's headline
  -- node:end_() is exclusive (one past the last row of the section),
  -- so the inclusive row range is [start_row, end_row - 1].
  --
  -- Heading pad (start_row): (L-1)*shift under literal stars; 0 when
  -- stars are visually replaced (the conceal mode supplies its own
  -- nesting via N-1 leading spaces).
  -- Body pad (start_row+1 .. end_row-1): aligns with the title text
  -- column.  Under literal stars the title sits at (L-1)*shift + L + 1
  -- bytes in (heading pad + stars + space); under stars-hidden modes
  -- the rendered title starts at column L+2, so the body pad is L+1.
  local function visit(node, level)
    local start_row = node:start()
    local end_row = node:end_()
    local heading_pad_size = hide_stars and 0 or ((level - 1) * shift)
    local body_pad_size = hide_stars and (level + 1) or ((level - 1) * shift + level + 1)

    if heading_pad_size > 0 and start_row >= topline and start_row <= botline then
      frame_map[start_row] = string.rep(" ", heading_pad_size)
    elseif start_row >= topline and start_row <= botline then
      -- Explicit clear: a previous outer visit may have written a
      -- body_pad here.  An absent entry on the heading row is what
      -- on_line treats as "no virt_text".
      frame_map[start_row] = nil
    end

    if body_pad_size > 0 then
      local lo = math.max(start_row + 1, topline)
      local hi = math.min(end_row - 1, botline)
      if lo <= hi then
        local pad = string.rep(" ", body_pad_size)
        for ln = lo, hi do
          frame_map[ln] = pad
        end
      end
    end

    for child in node:iter_children() do
      if child:type() == "headline" then
        local csr = child:start()
        local cer = child:end_()
        if cer >= topline and csr <= botline then
          visit(child, heading_level(child))
        end
      end
    end
  end

  for child in root:iter_children() do
    if child:type() == "headline" then
      local csr = child:start()
      local cer = child:end_()
      if cer >= topline and csr <= botline then
        visit(child, heading_level(child))
      end
    end
  end
end

local function on_line(bufnr, _winid, row)
  local pad = frame_map[row]
  if not pad then
    return
  end
  local cfg = get_config()
  local hl = cfg.hl_group or "Conceal"
  -- right_gravity=false anchors the extmark to its position BEFORE
  -- insertions at the same column, so typing at the start of a body
  -- line inserts AFTER the virt-text indent (correct) rather than
  -- shifting the virt-text rightward of the typed char (which would
  -- visually look like the typed text overwrites the indent).
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
    virt_text = { { pad, hl } },
    virt_text_pos = "inline",
    right_gravity = false,
    ephemeral = true,
  })
end

require("organ.decoration").register({
  name = "indent",
  ns = NS,
  enabled = function(bufnr)
    return M._attached[bufnr] == true
  end,
  on_win = on_win,
  on_line = on_line,
})

-- Drive on_win full-buffer and place non-ephemeral extmarks for every
-- populated row.  Test-facing: assertions via `nvim_buf_get_extmarks`
-- need real (non-ephemeral) marks, which the on_line path doesn't
-- produce.  Also the immediate-render entrypoint for attach().
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  on_win(bufnr, 0, 0, n - 1)
  local cfg = get_config()
  local hl = cfg.hl_group or "Conceal"
  for row, pad in pairs(frame_map) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
      virt_text = { { pad, hl } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
  end
end

M._frame_map = function()
  return frame_map
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
