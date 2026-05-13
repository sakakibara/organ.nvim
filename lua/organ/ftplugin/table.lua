-- lua/organ/ftplugin/table.lua
-- Buffer-local attach for table navigation and menu keymaps.

local M = {}

function M.attach(bufnr)
  local table_cfg = require("organ.buf_config").read(bufnr, "table") or {}
  if table_cfg.enabled == false then
    return
  end
  -- Rule 2: keymaps = false disables all bindings for this feature.
  if table_cfg.keymaps == false then
    return
  end
  local table_mod = require("organ.table")
  local cfg = table_cfg.keymaps or {}

  local function table_dispatch(direction)
    return function()
      -- Tempo first (insert-mode `<Tab>` only): if the cursor sits right
      -- after a `<KEY` trigger, expand to a structure block. Tempo is
      -- opt-out via `tempo.enabled = false`.
      if direction == "next" then
        local tempo_cfg = (require("organ.buf_config").read(nil, "tempo") or {})
        if tempo_cfg.enabled ~= false and vim.fn.mode() == "i" then
          if require("organ.tempo").expand(0) then
            return
          end
        end
      end
      local handled = direction == "next" and table_mod.tab(0) or table_mod.shift_tab(0)
      if not handled then
        local line = vim.fn.line(".")
        local cur_lines = vim.api.nvim_buf_get_lines(0, line - 1, line, false)
        local on_heading = cur_lines[1] and cur_lines[1]:match("^%*+%s") ~= nil
        local is_normal = vim.fn.mode() == "n"

        if direction == "next" then
          -- <Tab>: cycle local fold ONLY on a heading; elsewhere fall
          -- through to the default <Tab> (insert-mode tab, normal-mode noop).
          if on_heading then
            require("organ.fold").cycle(0, line)
          else
            local seq = vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
            vim.api.nvim_feedkeys(seq, "n", false)
          end
        else
          -- <S-Tab>: in normal mode, ALWAYS cycle global folds — matches
          -- Emacs org-mode behavior where S-TAB works regardless of cursor
          -- position. In insert mode (non-table here), fall through to
          -- whatever <S-Tab> does there (typically nothing).
          if is_normal then
            require("organ.fold").cycle_global(0)
          else
            local seq = vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true)
            vim.api.nvim_feedkeys(seq, "n", false)
          end
        end
      end
    end
  end

  local DESCS = {
    next_cell = "Next table cell",
    prev_cell = "Previous table cell",
  }

  local function map(name, direction, lhs_default, mode_list)
    local lhs = cfg[name]
    if lhs == false then
      return
    end
    if lhs == nil or lhs == "" then
      lhs = lhs_default
    end
    for _, mode in ipairs(mode_list) do
      vim.api.nvim_buf_set_keymap(bufnr, mode, lhs, "", {
        noremap = true,
        silent = true,
        desc = DESCS[name] or name,
        callback = table_dispatch(direction),
      })
    end
  end

  map("next_cell", "next", "<Tab>", { "i", "n" })
  map("prev_cell", "prev", "<S-Tab>", { "i", "n" })

  -- Table menu keymap.
  local menu_lhs = cfg.menu
  if menu_lhs and menu_lhs ~= "" and menu_lhs ~= false then
    vim.api.nvim_buf_set_keymap(bufnr, "n", menu_lhs, "", {
      noremap = true,
      silent = true,
      desc = "Table menu",
      callback = function()
        require("organ.table").open_menu()
      end,
    })
  end
end

return M
