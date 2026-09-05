-- lua/organ/ftplugin/undo.lua
-- `b:undo_ftplugin` for org buffers.  Neovim runs it when the buffer's
-- filetype moves away from org, before the next filetype's plugin loads,
-- so everything the org ftplugin installed has to come off here: the
-- buffer-local keymaps, the buffer and window options, the per-buffer
-- augroups, and the decoration providers.

local M = {}

local MODES = { "n", "i", "v", "x", "s", "o", "c", "t" }

local BUF_OPTIONS = "formatexpr< indentexpr< indentkeys< omnifunc<"
local WIN_OPTIONS = "foldmethod< foldexpr< foldenable< foldlevel< foldminlines<"
  .. " foldtext< statuscolumn< fillchars< winhighlight< conceallevel< concealcursor<"

-- Modules the ftplugin attaches that own per-buffer extmarks or state.
local DETACHABLE = {
  "organ.indent",
  "organ.stars",
  "organ.entities",
  "organ.conceal",
  "organ.description_list",
  "organ.decoration",
}

-- bufnr -> set of "mode\0lhs" present before the ftplugin ran.  Anything
-- mapped on top of that is organ's and comes off again.
local baseline = {}

local function keymaps(bufnr)
  local out = {}
  for _, mode in ipairs(MODES) do
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      out[#out + 1] = { mode = mode, lhs = m.lhs, key = mode .. "\0" .. m.lhs }
    end
  end
  return out
end

-- Record the pre-ftplugin keymaps (first attach only) and publish the
-- undo command.  Called from `organ.ftplugin.core.attach`, which both the
-- ftplugin and the FileType-autocmd path run before any other attach.
function M.install(bufnr)
  if not baseline[bufnr] then
    local set = {}
    for _, m in ipairs(keymaps(bufnr)) do
      set[m.key] = true
    end
    baseline[bufnr] = set
    require("organ.buf_state").on_cleanup(bufnr, "ft_undo", function(b)
      baseline[b] = nil
    end)
  end
  vim.b[bufnr].undo_ftplugin = "lua require('organ.ftplugin.undo').run(" .. bufnr .. ")"
  -- `b:undo_ftplugin` is run by Neovim's ftplugin.vim.  organ also attaches
  -- from a FileType autocmd for sessions where filetype plugins are off
  -- (see organ.setup), and those need the teardown too; `run` is a no-op
  -- after the first call, so both paths firing costs nothing.
  local group = vim.api.nvim_create_augroup("organ_ftundo_" .. bufnr, { clear = true })
  require("organ.errors").autocmd("FileType", {
    group = group,
    buffer = bufnr,
    callback = function(ev)
      if vim.bo[ev.buf].filetype ~= "org" then
        M.run(ev.buf)
      end
    end,
  })
end

function M.run(bufnr)
  bufnr = tonumber(bufnr) or vim.api.nvim_get_current_buf()
  local base = baseline[bufnr]
  baseline[bufnr] = nil
  if not base or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_name, "organ_ftundo_" .. bufnr)

  for _, m in ipairs(keymaps(bufnr)) do
    if not base[m.key] then
      pcall(vim.api.nvim_buf_del_keymap, bufnr, m.mode, m.lhs)
    end
  end

  for _, mod in ipairs(DETACHABLE) do
    pcall(function()
      require(mod).detach(bufnr)
    end)
  end
  -- Same per-buffer teardown a wipeout drains (fold caches, modern engine,
  -- completion and `#+TODO:` augroups).
  pcall(function()
    require("organ.buf_state").cleanup(bufnr)
  end)
  pcall(vim.api.nvim_del_augroup_by_name, "organ_foldwin_" .. bufnr)

  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("setlocal " .. BUF_OPTIONS)
  end)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd("setlocal " .. WIN_OPTIONS)
    end)
    pcall(function()
      require("organ.conceal").forget_window(win)
    end)
  end
end

return M
