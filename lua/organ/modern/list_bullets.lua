-- Plain list bullets for modern mode.
--
-- `- item` / `+ item` -> the bullet is concealed and replaced by a single-
-- cell `•` colored via @org.list.bullet. Ordered bullets (1. / 1)) are left
-- untouched. Rendered through the persistent engine.

local M = {}

local BULLET_HL = "@org.list.bullet"

local _q
local function query()
  if _q then
    return _q
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, "org", [[
    (list_item bullet: (bullet) @b)
  ]])
  if ok then
    _q = parsed
  end
  return _q
end

local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.list_bullets") then
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

  local ns = require("organ.modern.render").ns
  local glyph = require("organ.modern.glyphs").get("list.bullet", bufnr)
  if glyph == "" then
    return
  end

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, sc, er = node:range()
    if sr == er then
      local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
      -- The bullet node carries a trailing space (`"- "`); match the leading
      -- char and conceal only it, leaving the space so text stays spaced.
      local ch = ok_text and type(text) == "string" and text:sub(1, 1)
      if ch == "-" or ch == "+" then
        vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
          end_col = sc + 1,
          conceal = "",
          priority = 200,
        })
        vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
          virt_text = { { glyph, BULLET_HL } },
          virt_text_pos = "inline",
          priority = 200,
        })
      end
    end
  end
end

require("organ.modern.render").register("list_bullets", render)

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
  require("organ.modern.render").attach(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  require("organ.modern.render").detach(bufnr)
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "modern.list_bullets")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.list_bullets") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
