-- lua/organ/ftplugin/tag_select.lua
-- Buffer-local attach for the fast-tag-selection keymap.

local M = {}

function M.attach(bufnr)
  local tags_cfg = require("organ.buf_config").read(nil, "tags") or {}
  if tags_cfg.keymaps == false then
    return
  end
  local km = tags_cfg.keymaps or {}
  local lhs = km.set
  if lhs == false or lhs == nil or lhs == "" then
    return
  end
  vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
    noremap = true,
    silent = true,
    desc = "Set tags (fast-select)",
    callback = function()
      require("organ.tag_select").run()
    end,
  })
end

return M
