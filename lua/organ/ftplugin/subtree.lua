-- lua/organ/ftplugin/subtree.lua
-- Buffer-local attach for structure keymaps.

local M = {}

function M.attach(bufnr)
  local struct_cfg = require("organ").config.structure or {}
  if struct_cfg.enabled == false then
    return
  end
  -- Rule 2: keymaps = false disables all bindings for this feature.
  if struct_cfg.keymaps == false then
    return
  end
  local cfg = struct_cfg.keymaps or {}
  -- All slot → command mappings, including the *_alt aliases so users with
  -- no Alt-key support can stay productive. The same callback (with count
  -- support) is installed for both primary and alt variants.
  -- Each value is the dispatch path resolved via `require("organ").cmd`.
  local cmd_map = {
    promote_subtree = "promote",
    demote_subtree = "demote",
    promote_subtree_alt = "promote",
    demote_subtree_alt = "demote",
    promote_headline = "promote_headline",
    demote_headline = "demote_headline",
    promote_headline_alt = "promote_headline",
    demote_headline_alt = "demote_headline",
    move_subtree_up = "move_up",
    move_subtree_down = "move_down",
    move_subtree_up_alt = "move_up",
    move_subtree_down_alt = "move_down",
    meta_return = "meta_return",
  }
  local descs = {
    promote_subtree = "promote subtree",
    demote_subtree = "demote subtree",
    promote_subtree_alt = "promote subtree (alt)",
    demote_subtree_alt = "demote subtree (alt)",
    promote_headline = "promote headline",
    demote_headline = "demote headline",
    promote_headline_alt = "promote headline (alt)",
    demote_headline_alt = "demote headline (alt)",
    move_subtree_up = "move subtree up",
    move_subtree_down = "move subtree down",
    move_subtree_up_alt = "move subtree up (alt)",
    move_subtree_down_alt = "move subtree down (alt)",
    meta_return = "insert element below (M-RET)",
  }
  local function dispatch(path)
    local entry = require("organ").cmd(path)
    if not entry or not entry.fn then
      require("organ.notify").warn("organ: subcommand `" .. path .. "` not registered")
      return
    end
    entry.fn({ args = "", fargs = {} })
  end

  for key, path in pairs(cmd_map) do
    local lhs = cfg[key]
    if lhs and lhs ~= "" and lhs ~= false then
      -- Normal-mode binding for every action.
      vim.api.nvim_buf_set_keymap(bufnr, "n", lhs, "", {
        noremap = true,
        silent = true,
        desc = descs[key] or key,
        callback = function()
          -- Honor `vim.v.count` so `2>>` demotes twice, `3<<` promotes
          -- thrice, etc. Default count is 0 which we map to 1.
          local n = math.max(1, vim.v.count1)
          for _ = 1, n do
            dispatch(path)
          end
        end,
      })
      -- meta_return: also bind in insert mode so users in the middle of
      -- typing can press <M-CR> to drop into a fresh sibling element.
      -- The other ops are normal-mode-only (count semantics + cursor moves
      -- don't make sense from insert).
      if key == "meta_return" then
        vim.api.nvim_buf_set_keymap(bufnr, "i", lhs, "", {
          noremap = true,
          silent = true,
          desc = descs[key] or key,
          callback = function()
            vim.cmd("stopinsert")
            dispatch(path)
            vim.schedule(function()
              vim.cmd("startinsert!")
            end)
          end,
        })
      end
    end
  end
end

return M
