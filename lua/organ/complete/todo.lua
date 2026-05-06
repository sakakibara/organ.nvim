-- TODO-keyword completion source.
--
-- Trigger: cursor is in the first-word position of a headline (after
-- the stars + one space, before any second whitespace). Surfaces the
-- configured `todo.sequence` plus a fast-path for the common case of
-- a fresh `* ` headline (no existing keyword).
--
-- Stays silent when:
--   - line isn't a headline
--   - cursor is past the first word (a TODO keyword wouldn't go there)
--   - line already has a TODO keyword AND the partial doesn't refine it
--     (avoids suggesting `TODO` when the user just moved past existing
--     `TODO`)

local M = {}

-- Returns nil when not in a TODO-completion context. Returns the
-- partial keyword being typed (may be "") when in context.
-- `row` (1-based) and `col` (0-based byte) optional — defaults to the
-- current window cursor.
function M.cursor_partial(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if row == nil or col == nil then
    local pos = vim.api.nvim_win_get_cursor(0)
    row = row or pos[1]
    col = col or pos[2]
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local stars = line:match("^(%*+) ")
  if not stars then
    return nil
  end
  local first_word_start = #stars + 1 -- position right after `* `
  if col < first_word_start then
    return nil
  end
  local before = line:sub(1, col)
  -- Cursor must be in the first-word slot (no whitespace between stars
  -- and cursor).
  local first_word = before:sub(first_word_start + 1)
  if first_word:find("%s") then
    return nil
  end
  return first_word
end

-- Build keyword list from config.todo.sequence, dropping the `|`
-- separator. Each item carries a `done` flag for icon hints.
function M.completion_items(partial)
  partial = (partial or ""):upper()
  local cfg = require("organ").config or {}
  local seq = (cfg.todo or {}).sequence or { "TODO", "DONE" }
  local in_done = false
  local items = {}
  for _, kw in ipairs(seq) do
    if kw == "|" then
      in_done = true
    else
      if partial == "" or kw:upper():find(partial, 1, true) == 1 then
        items[#items + 1] = {
          label = kw,
          insertText = kw,
          filterText = kw,
          kind = "Keyword",
          done = in_done,
        }
      end
    end
  end
  return items
end

return M
