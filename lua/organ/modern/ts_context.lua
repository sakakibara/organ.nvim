-- Modern bullets inside nvim-treesitter-context's sticky header.
--
-- The context header is a scratch buffer holding copies of the headline
-- lines. treesitter-context carries over only extmarks from core `nvim.*`
-- namespaces, and its copy drops the `conceal` field, so the bullet
-- conceals from organ.modern.bullets never reach the header -- it shows
-- literal `*` stars while the buffer shows glyphs.
--
-- This decoration provider spots context windows (marked with
-- `w:treesitter_context` by the plugin) whose parent window holds an org
-- buffer with `modern.bullets` enabled, and applies the same star
-- treatment to the context buffer as ephemeral conceal marks: the leading
-- N-1 stars as spaces, the last star as the per-level glyph. The context
-- window inherits `conceallevel` from the parent window, so the conceals
-- render without touching its options.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_modern_ts_context")

-- context winid -> parent org bufnr, set by on_win for the on_line calls
-- of the same redraw cycle.
local win_parent = {}

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
    if not require("organ.buf_config").read(pbuf, "modern.bullets") then
      return false
    end
    win_parent[winid] = pbuf
    return true
  end,
  on_line = function(_, winid, bufnr, row)
    local pbuf = win_parent[winid]
    if not pbuf then
      return
    end
    local line = (vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false) or {})[1] or ""
    local stars = line:match("^(%*+)%s") or line:match("^(%*+)$")
    if not stars then
      return
    end
    local n = #stars
    for i = 0, n - 2 do
      vim.api.nvim_buf_set_extmark(bufnr, NS, row, i, {
        end_col = i + 1,
        conceal = " ",
        ephemeral = true,
        priority = 200,
      })
    end
    vim.api.nvim_buf_set_extmark(bufnr, NS, row, n - 1, {
      end_col = n,
      conceal = require("organ.modern.bullets").glyph(pbuf, n),
      hl_group = require("organ.highlights").heading_title_hl(n),
      ephemeral = true,
      priority = 200,
    })
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = vim.api.nvim_create_augroup("organ_modern_ts_context", { clear = true }),
  callback = function(ev)
    win_parent[tonumber(ev.match)] = nil
  end,
})

return M
