-- lua/organ/ftplugin/property.lua
-- Buffer-local attach for property keymaps.

local M = {}

function M.attach(bufnr)
  local prop_cfg = require("organ").config.property or {}
  if prop_cfg.enabled == false then
    return
  end
  -- Rule 2: keymaps = false disables all bindings for this feature.
  if prop_cfg.keymaps == false then
    return
  end
  local cfg = prop_cfg.keymaps or {}
  local prop = require("organ.property")
  local function map(name, fn, desc)
    local lhs = cfg[name]
    if lhs == false or lhs == nil or lhs == "" then
      return
    end
    vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      desc = desc,
      callback = function()
        fn(0, vim.fn.line("."))
      end,
    })
  end
  map("set", prop.set_interactive, "Set property")
  map("delete", prop.delete_interactive, "Delete property")
end

return M
