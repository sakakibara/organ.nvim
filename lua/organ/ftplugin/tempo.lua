-- lua/organ/ftplugin/tempo.lua
-- Standalone insert-mode <Tab> mapping for tempo expansion. Installs ONLY
-- when the table ftplugin won't (i.e. when table.enabled is false but
-- tempo.enabled is true) — table.lua's dispatcher already integrates tempo.

local M = {}

function M.attach(bufnr)
  local cfg = require("organ").config
  local tempo_cfg = cfg.tempo or {}
  if tempo_cfg.enabled == false then
    return
  end
  local table_cfg = cfg["table"] or {}
  -- Skip when table will own the <Tab> mapping; table_dispatch already calls tempo.
  if table_cfg.enabled ~= false and table_cfg.keymaps ~= false then
    return
  end

  vim.api.nvim_buf_set_keymap(bufnr, "i", "<Tab>", "", {
    noremap = true,
    silent = true,
    desc = "Expand tempo block / Tab",
    callback = function()
      if require("organ.tempo").expand(bufnr) then
        return
      end
      local seq = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
      vim.api.nvim_feedkeys(seq, "n", false)
    end,
  })
end

return M
