-- Checkboxes for modern mode.
--
-- `- [ ] x` / `- [X] x` / `- [-] x` -> the `[ ]` is concealed and replaced by
-- a single-cell state icon (nerd mode) or colored in place (ascii mode).
-- Rendered through the persistent engine; the conceal + inline-glyph pair
-- collapses the 3-cell box to one colored cell with following text aligned.

local M = {}

-- state -> semantic color group. Recomputed after ColorScheme.
local STATE_GROUP = {
  empty = "Comment",
  checked = "DiagnosticOk",
  partial = "DiagnosticWarn",
}
local _hl_dirty = true
local function ensure_highlights()
  if not _hl_dirty then
    return
  end
  local resolved = require("organ.highlights").resolved_fg
  for state, group in pairs(STATE_GROUP) do
    local fg = resolved(group)
    if fg then
      vim.api.nvim_set_hl(0, "@organ.modern.checkbox." .. state, { fg = fg })
    end
  end
  _hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_checkboxes_hl", { clear = true }),
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
    (list_item checkbox: (checkbox) @c)
  ]])
  if ok then
    _q = parsed
  end
  return _q
end

-- Middle char of `[ ]`/`[X]`/`[x]`/`[-]` -> state name. The checkbox node
-- carries a trailing space (`"[X] "`), so match the bracket prefix only (no
-- `$` anchor).
local function state_of(text)
  local c = text:match("^%[(.)%]")
  if c == " " or c == nil then
    return "empty"
  elseif c == "-" then
    return "partial"
  end
  return "checked"
end

local function render(bufnr, top, bot)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if not require("organ.buf_config").read(bufnr, "modern.checkboxes") then
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
  local glyphs = require("organ.modern.glyphs")

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, sc, er = node:range()
    if sr == er then
      local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
      if ok_text and type(text) == "string" then
        local state = state_of(text)
        local hl = "@organ.modern.checkbox." .. state
        local glyph = glyphs.get("checkbox." .. state, bufnr)
        -- The bracket is the first 3 bytes (`[x]`); the node may carry a
        -- trailing space -- leave it so text stays spaced from the icon.
        local box_end = sc + 3
        if glyph == "" then
          -- ascii / no-icon: color the raw box in place.
          vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
            end_col = box_end,
            hl_group = hl,
            priority = 200,
          })
        else
          vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
            end_col = box_end,
            conceal = "",
            priority = 200,
          })
          vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
            virt_text = { { glyph, hl } },
            virt_text_pos = "inline",
            priority = 200,
          })
        end
      end
    end
  end
end

require("organ.modern.render").register("checkboxes", render)

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
  local on = require("organ.buf_config").toggle(bufnr, "modern.checkboxes")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.checkboxes") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
