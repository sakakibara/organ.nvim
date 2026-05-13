-- lua/organ/ftplugin/inline_edit.lua
-- Buffer-local attach for inline-edit keymaps.

local M = {}

function M.attach(bufnr)
  local ie_cfg = require("organ.buf_config").read(nil, "inline_edit") or {}
  if ie_cfg.enabled == false then
    return
  end
  -- Rule 2: keymaps = false disables all bindings for this feature.
  if ie_cfg.keymaps == false then
    return
  end
  local cfg = ie_cfg.keymaps or {}
  local function map(name, direction, desc)
    local lhs = cfg[name]
    if lhs == false or lhs == nil or lhs == "" then
      return
    end
    vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
      noremap = true,
      silent = true,
      desc = desc,
      callback = function()
        require("organ.inline_edit").dispatch(direction)
      end,
    })
  end
  map("increment", "inc", "Increment value at cursor")
  map("decrement", "dec", "Decrement value at cursor")
end

return M
