-- Property drawers for modern mode.
--
-- `:PROPERTIES:` .. `:END:` (and generic `:DRAWER:` blocks) -> the whole
-- drawer dims to a muted color and the header gains a collapse/leaf glyph.
-- Structural bookkeeping should read quietly. Rendered through the persistent
-- engine (a multi-line hl_group over the drawer + an inline glyph on line 1).

local M = {}

local DRAWER_GROUP = "Comment"

local _hl_dirty = true
local function ensure_highlights()
  if not _hl_dirty then
    return
  end
  local fg = require("organ.highlights").resolved_fg(DRAWER_GROUP)
  if fg then
    vim.api.nvim_set_hl(0, "@organ.modern.drawer", { fg = fg })
  end
  _hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_drawers_hl", { clear = true }),
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
    (property_drawer) @d
    (drawer) @d
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
  if not require("organ.buf_config").read(bufnr, "modern.drawers") then
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
  local glyph = require("organ.modern.glyphs").get("drawer.leaf", bufnr)
  local last = vim.api.nvim_buf_line_count(bufnr)

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, sc, er, ec = node:range()
    -- Dim the whole drawer. The node range spans to the line after `:END:`
    -- (trailing newline), so end_row/end_col cover every drawer line.
    vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
      end_row = math.min(er, last),
      end_col = ec,
      hl_group = "@organ.modern.drawer",
      priority = 200,
    })
    -- Leaf glyph on the header line, before the opening `:`.
    if glyph ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
        virt_text = { { glyph .. " ", "@organ.modern.drawer" } },
        virt_text_pos = "inline",
        priority = 200,
      })
    end
  end
end

require("organ.modern.render").register("drawers", render)

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
  local on = require("organ.buf_config").toggle(bufnr, "modern.drawers")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.drawers") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
