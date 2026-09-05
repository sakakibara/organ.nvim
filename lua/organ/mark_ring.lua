-- Org's own mark ring -- Emacs org-mark-ring-push / org-mark-ring-goto
-- (C-c %, C-c &).
--
-- Neovim's jumplist already records jumps, but it is window-local,
-- pruned when a window closes, and shared with every other motion, so a
-- link jump is quickly buried under ordinary navigation.  Org's ring is
-- a small global stack of positions org commands chose to remember, and
-- repeated `goto` walks it.  Both are kept: a push also sets a jumplist
-- entry (Emacs pushes onto the Emacs mark ring alongside its own), so
-- `<C-o>` still works and the ring stays available for the deliberate
-- "walk back through where org sent me" case.

local M = {}

-- Newest first.  Each entry is { file = <path>, line = N, col = N }.
M._ring = {}
-- How far into the ring the last `goto` walked, so repeated calls step
-- deeper instead of bouncing on the newest entry.
M._at = nil

local function ring_length()
  local cfg = require("organ.buf_config").read(nil, "mark_ring") or {}
  local n = tonumber(cfg.length) or 4
  return math.max(1, math.floor(n))
end

-- Record a position (defaults to the cursor).  Also drops a jumplist
-- entry so Neovim's own `<C-o>` keeps working.
function M.push(pos)
  local entry
  if pos then
    entry = { file = pos.file, line = pos.line, col = pos.col or 0 }
  else
    local cur = vim.api.nvim_win_get_cursor(0)
    entry = { file = vim.api.nvim_buf_get_name(0), line = cur[1], col = cur[2] }
    pcall(vim.cmd, "normal! m'")
  end
  if entry.file == nil or entry.file == "" then
    return nil, "cannot mark a buffer with no file"
  end
  table.insert(M._ring, 1, entry)
  local max = ring_length()
  while #M._ring > max do
    table.remove(M._ring)
  end
  M._at = nil
  return entry
end

-- Jump to the `n`th stored position (default: one step).  Consecutive
-- calls walk deeper into the ring; any push resets the walk.
function M.goto_mark(n)
  if #M._ring == 0 then
    return nil, "org mark ring is empty"
  end
  n = math.max(1, math.floor(tonumber(n) or 1))
  local at = ((M._at or 0) + n - 1) % #M._ring + 1
  M._at = at
  local entry = M._ring[at]
  local bufnr = vim.fn.bufadd(entry.file)
  vim.fn.bufload(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  local last = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(entry.line, last), entry.col })
  return entry
end

function M.clear()
  M._ring = {}
  M._at = nil
end

M.commands = {
  ["mark_ring push"] = {
    fn = function()
      local entry, why = M.push()
      if not entry then
        require("organ.notify").warn(why)
        return
      end
      require("organ.notify").info("position saved to the org mark ring")
    end,
    desc = "Save the cursor position to the org mark ring (Emacs C-c %)",
  },
  ["mark_ring goto"] = {
    fn = function(cmd)
      local n = tonumber(cmd and cmd.args) or 1
      local entry, why = M.goto_mark(n)
      if not entry then
        require("organ.notify").warn(why)
      end
    end,
    nargs = "?",
    desc = "Jump back to a position on the org mark ring (Emacs C-c &)",
  },
}

return M
