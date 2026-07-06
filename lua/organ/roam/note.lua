-- Shared construction of an org-roam-style file node header, used by both
-- `organ.roam` (nodes) and `organ.roam.dailies`.  Keeps the two in lock-step
-- with each other and with what Emacs org-roam writes.

local M = {}

-- File-level node header: the :ID: property drawer followed by #+title.
-- The :ID: line is formatted through the shared property formatter so its
-- org-property-format alignment matches every other :ID: organ writes.
function M.header(id, title)
  return {
    ":PROPERTIES:",
    require("organ.property").format_line("ID", id),
    ":END:",
    "#+title: " .. title,
  }
end

-- Open `path` as a NEW unsaved buffer seeded with `lines`.  The parent
-- directory creation and the first write are deferred to the user's first
-- save, so a brand-new note opened and abandoned untouched leaves nothing on
-- disk (matches Emacs org-roam capture).  Cursor lands at the end of the last
-- seeded line so typing continues it.  Callers guarantee `path` does not yet
-- exist on disk; existing files are opened normally by the caller.
function M.open_unsaved(path, lines)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.fn.mkdir(dir, "p")
    end,
  })
  local last = vim.api.nvim_buf_line_count(bufnr)
  local last_text = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { last, #last_text })
  return bufnr
end

return M
