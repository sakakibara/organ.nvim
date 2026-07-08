-- Directive lines for modern mode.
--
-- `#+TITLE: value` / `#+CAPTION: value` etc. -> the `#+KEYWORD:` label dims
-- to a muted color; the value reads normal. Structural bookkeeping should not
-- compete with content. Rendered through the persistent engine (an hl_group
-- overlay over the label bytes -- nothing width-adding).

local M = {}

local DIRECTIVE_GROUP = "Comment"

local _hl_dirty = true
local function ensure_highlights()
  if not _hl_dirty then
    return
  end
  local fg = require("organ.highlights").resolved_fg(DIRECTIVE_GROUP)
  if fg then
    vim.api.nvim_set_hl(0, "@organ.modern.directive", { fg = fg })
  end
  _hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_directives_hl", { clear = true }),
  callback = function()
    _hl_dirty = true
  end,
})

local _q
local function query()
  if _q then
    return _q
  end
  local ok, parsed = pcall(
    vim.treesitter.query.parse,
    "org",
    [[
    (keyword) @k
    (affiliated_keyword) @k
  ]]
  )
  if ok then
    _q = parsed
  end
  return _q
end

local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.directives") then
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

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, sc = node:range()
    -- Dim `#+KEYWORD:` up to the value; if there is no value, dim the line.
    local value = node:field("value")[1]
    local end_col
    if value then
      local _, vsc = value:range()
      end_col = vsc
    else
      local ltext = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1] or ""
      end_col = #ltext
    end
    if end_col > sc then
      vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
        end_row = sr,
        end_col = end_col,
        hl_group = "@organ.modern.directive",
        priority = 200,
      })
    end
  end
end

require("organ.modern.render").register("directives", render)

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
  local on = require("organ.buf_config").toggle(bufnr, "modern.directives")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.directives") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
