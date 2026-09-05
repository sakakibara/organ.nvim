-- Star treatments inside nvim-treesitter-context's sticky header.
--
-- The context header is a scratch buffer holding copies of the headline
-- lines. treesitter-context carries over only extmarks from core `nvim.*`
-- namespaces, and its copy drops the `conceal` field, so the star conceals
-- from organ.modern.bullets / organ.stars never reach the header -- it
-- shows literal `*` stars while the buffer shows glyphs or hidden stars.
--
-- This decoration provider spots context windows (marked with
-- `w:treesitter_context` by the plugin) whose parent window holds an org
-- buffer with a star treatment enabled, and applies the same treatment to
-- the context buffer as ephemeral conceal marks:
--   modern.bullets  leading N-1 stars as spaces, last star as the
--                   per-level glyph
--   stars.hide      leading N-1 stars as spaces, last star kept
-- treesitter-context copies `conceallevel` into the float only when it
-- CREATES it, so a treatment toggled on after that would never render
-- there; the provider keeps the float's conceallevel synced to the
-- parent window's (deferred -- window options must not change
-- mid-redraw).

local M = {}

local NS = vim.api.nvim_create_namespace("organ_ts_context")

-- context winid -> { buf = parent org bufnr, mode = "bullets"|"stars" },
-- set by on_win for the on_line calls of the same redraw cycle.
local win_parent = {}

local function star_mode(pbuf)
  local bc = require("organ.buf_config")
  if bc.read(pbuf, "modern.bullets") then
    return "bullets"
  end
  if bc.read(pbuf, "stars.hide") == true then
    return "stars"
  end
end

local function conceallevel(winid)
  return vim.api.nvim_get_option_value("conceallevel", { win = winid, scope = "local" })
end

local function sync_conceallevel(winid, pwin)
  if conceallevel(winid) == conceallevel(pwin) then
    return
  end
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_is_valid(pwin) then
      pcall(vim.api.nvim_set_option_value, "conceallevel", conceallevel(pwin), {
        win = winid,
        scope = "local",
      })
    end
  end)
end

vim.api.nvim_set_decoration_provider(NS, {
  on_win = function(_, winid, _bufnr)
    win_parent[winid] = nil
    if vim.w[winid].treesitter_context ~= true then
      return false
    end
    local pwin = vim.api.nvim_win_get_config(winid).win
    if not pwin or not vim.api.nvim_win_is_valid(pwin) then
      return false
    end
    local pbuf = vim.api.nvim_win_get_buf(pwin)
    if vim.bo[pbuf].filetype ~= "org" then
      return false
    end
    local mode = star_mode(pbuf)
    if not mode then
      return false
    end
    sync_conceallevel(winid, pwin)
    win_parent[winid] = { buf = pbuf, mode = mode }
    return true
  end,
  on_line = function(_, winid, bufnr, row)
    local parent = win_parent[winid]
    if not parent then
      return
    end
    local line = (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false) or {})[1] or ""
    local stars = line:match("^(%*+) ")
    if not stars then
      return
    end
    local n = #stars
    for i = 0, n - 2 do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, i, {
        end_col = i + 1,
        conceal = " ",
        ephemeral = true,
        priority = 200,
      })
    end
    if parent.mode == "bullets" then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, n - 1, {
        end_col = n,
        conceal = require("organ.modern.bullets").glyph(parent.buf, n),
        hl_group = require("organ.highlights").heading_title_hl(n),
        ephemeral = true,
        priority = 200,
      })
    end
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("organ_ts_context", { clear = true }),
  callback = function(ev)
    win_parent[tonumber(ev.match)] = nil
  end,
})

return M
