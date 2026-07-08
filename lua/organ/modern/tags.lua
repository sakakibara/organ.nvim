-- Tags for modern mode.
--
-- `* Title :work:client:` -> the `:work:client:` is concealed in the buffer
-- and re-emitted rightmost in the right-aligned metadata column as a muted
-- `work <sep> client` run. Rendered through the persistent engine and
-- composed by organ.modern.layout (slot = tags, rightmost).

local M = {}

local TAG_GROUP = "Comment"

local _hl_dirty = true
local function ensure_highlights()
  if not _hl_dirty then
    return
  end
  local fg = require("organ.highlights").resolved_fg(TAG_GROUP)
  if fg then
    vim.api.nvim_set_hl(0, "@organ.modern.tag", { fg = fg })
  end
  _hl_dirty = false
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("organ_modern_tags_hl", { clear = true }),
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
    (headline_line tag_list: (tag_list) @tl)
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
  if not require("organ.buf_config").read(bufnr, "modern.tags") then
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
  local layout = require("organ.modern.layout")
  local glyphs = require("organ.modern.glyphs")
  local cfg = require("organ.buf_config").read(bufnr, "modern.tags")
  local badge = type(cfg) == "table" and cfg.style == "badge"
  local sep = glyphs.get("tag.sep", bufnr)
  local bl = glyphs.get("tag.badge.left", bufnr)
  local br = glyphs.get("tag.badge.right", bufnr)

  for _, node in q:iter_captures(tree:root(), bufnr, top, bot) do
    local sr, sc, er, ec = node:range()
    if sr == er then
      local ok_text, text = pcall(vim.treesitter.get_node_text, node, bufnr)
      if ok_text and type(text) == "string" then
        local names = {}
        for name in text:gmatch("[^:]+") do
          names[#names + 1] = name
        end
        if #names > 0 then
          -- Conceal the raw :tags: inline.
          vim.api.nvim_buf_set_extmark(bufnr, ns, sr, sc, {
            end_col = ec,
            conceal = "",
            priority = 200,
          })
          -- Muted run "a <sep> b" (default) or badges "<a> <b>".
          local chunks = {}
          for i, name in ipairs(names) do
            if i > 1 then
              chunks[#chunks + 1] = { badge and " " or (" " .. sep .. " "), "@organ.modern.tag" }
            end
            local label = badge and (bl .. name .. br) or name
            chunks[#chunks + 1] = { label, "@organ.modern.tag" }
          end
          layout.add(bufnr, sr, layout.SLOT.tags, chunks)
        end
      end
    end
  end
end

require("organ.modern.render").register("tags", render)

function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = require("organ.modern.render").ns
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  render(bufnr, 0, vim.api.nvim_buf_line_count(bufnr))
  require("organ.modern.layout").flush(bufnr, ns)
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
  local on = require("organ.buf_config").toggle(bufnr, "modern.tags")
  return on and true or false
end

require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "modern.tags") then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
