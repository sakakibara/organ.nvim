-- Horizontal rule for modern mode.
--
-- `-----` (5+ dashes on their own line) -> a `─` run spanning the window's
-- text width, dimmed. Overlay virt_text fills past the short source line and
-- re-sizes on WinResized (the engine refreshes on resize). Rendered through
-- the persistent engine.

local M = {}

local RULE_GROUP = "NonText"

local _hl_dirty = true
local function ensure_highlights()
  if not _hl_dirty then
    return
  end
  local fg = require("organ.highlights").resolved_fg(RULE_GROUP)
  if fg then
    vim.api.nvim_set_hl(0, "@organ.modern.rule", { fg = fg })
  end
  _hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_rule_hl", { clear = true }),
  callback = function()
    _hl_dirty = true
  end,
})

local _q
local function query()
  if _q then
    return _q
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, "org", [[
    (horizontal_rule) @h
  ]])
  if ok then
    _q = parsed
  end
  return _q
end

-- Text-area width of the window showing `bufnr` (window width minus the
-- gutters), or a sane default when the buffer is not displayed.
local function text_width(bufnr)
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    win = vim.fn.bufwinid(bufnr)
  end
  if win == -1 then
    return 80
  end
  local info = vim.fn.getwininfo(win)[1]
  local w = vim.api.nvim_win_get_width(win) - (info and info.textoff or 0)
  return math.max(1, w)
end

local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.rule") then
    return
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok_parser or not parser then
    return
  end
  local trees = parser:parse({ top, bot })
  local tree = trees and trees[1]
  if not tree then
    return
  end
  local q = query()
  if not q then
    return
  end
  ensure_highlights()

  local ns = require("organ.modern.render").ns
  local glyph = require("organ.modern.glyphs").get("rule.line", bufnr)
  if glyph == "" then
    return
  end
  local line = string.rep(glyph, text_width(bufnr))

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr = node:range()
    vim.api.nvim_buf_set_extmark(bufnr, ns, sr, 0, {
      virt_text = { { line, "@organ.modern.rule" } },
      virt_text_pos = "overlay",
      hl_mode = "combine",
      priority = 200,
    })
  end
end

require("organ.modern.render").register("rule", render)

function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = require("organ.modern.render").ns
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  render(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  _hl_dirty = true
  require("organ.modern.render").attach(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  require("organ.modern.render").detach(bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.rule")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.rule") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
