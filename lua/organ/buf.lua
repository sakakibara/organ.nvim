-- Buffer-write helpers that no-op when the new content is byte-identical
-- to the existing content.  Wrap `vim.api.nvim_buf_set_lines` and
-- `vim.api.nvim_buf_set_text` so an operation that produces unchanged
-- text doesn't:
--   * mark the buffer as `modified`
--   * push an undo entry
--   * fire on_lines / on_bytes attach callbacks
--
-- Use throughout organ instead of the raw nvim_buf_set_* APIs so that
-- "confirm deadline with the same date", "set property to its current
-- value", "rewrite tag block to identical tags", "formatter that
-- produces identical output", etc. all leave the buffer's modified
-- state untouched.

local M = {}

-- Write `new_lines` (a list of strings) to the range [start, end_).
-- `bufnr` defaults to the current buffer (0).  `strict_indexing` is
-- always false to match the most common call shape used across organ.
function M.set_lines(bufnr, start, end_, new_lines)
  bufnr = bufnr or 0
  local current = vim.api.nvim_buf_get_lines(bufnr, start, end_, false)
  if vim.deep_equal(current, new_lines) then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, start, end_, false, new_lines)
end

-- Write `new_text` (a list of strings, one per line) to the byte range
-- [(sr, sc), (er, ec)).  Same no-op-on-equal contract as set_lines.
function M.set_text(bufnr, sr, sc, er, ec, new_text)
  bufnr = bufnr or 0
  local current = vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {})
  if vim.deep_equal(current, new_text) then
    return
  end
  vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, new_text)
end

return M
