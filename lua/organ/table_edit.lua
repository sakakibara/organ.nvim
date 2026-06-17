-- :Org table edit_field — open the cell at cursor in a small floating buffer
-- for distraction-free editing of long values (Emacs C-c `).
--
-- On commit (<CR> in normal mode, or :w):
--   * The cell is overwritten with the floating buffer's content.
--   * Embedded newlines collapse to spaces (org tables are single-line per
--     cell; multi-line content corrupts the layout).
--   * The table is realigned.
--
-- On cancel (q in normal mode, or :q!) the cell is left unchanged.

local M = {}

local obuf = require("organ.buf")
local table_mod = require("organ.table")

-- Locate the cell at cursor. Returns { table, row_idx, col_idx, text } or nil.
local function locate(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local t = table_mod._parse(lines, lnum)
  if not t then
    return nil
  end
  local row_idx = lnum - t.start_line + 1
  local row = t.rows[row_idx]
  if not row or row.sep then
    return nil
  end
  local raw_line = lines[lnum] or ""
  local col_0 = vim.api.nvim_win_get_cursor(0)[2]
  local col_idx = table_mod._cursor_to_cell(raw_line, col_0)
  if not col_idx then
    return nil
  end
  local text = (row.cells[col_idx] or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return {
    table = t,
    row_idx = row_idx,
    col_idx = col_idx,
    text = text,
    src_line = lnum,
  }
end

-- Replace cell (row_idx, col_idx) of the parsed table with `new_text`,
-- realign, and write back to the buffer.
local function commit(bufnr, ctx, new_text)
  -- Collapse newlines / leading-trailing whitespace; org table cells are
  -- single-line.
  new_text = (new_text or ""):gsub("[\n\r]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  ctx.table.rows[ctx.row_idx].cells[ctx.col_idx] = new_text
  local new_lines = table_mod._align(ctx.table.rows, ctx.table.indent)
  obuf.set_lines(bufnr, ctx.table.start_line - 1, ctx.table.end_line, new_lines)
end

-- Open a floating window with the cell text. Buffer-local mappings:
--   <CR> in normal mode → commit + close
--   q                   → cancel + close
--   :w                  → commit (no close)
--   :q!                 → cancel + close
function M.open(src_bufnr, src_line)
  src_bufnr = src_bufnr or vim.api.nvim_get_current_buf()
  src_line = src_line or vim.fn.line(".")
  local ctx = locate(src_bufnr, src_line)
  if not ctx then
    require("organ.notify").warn("not on a table cell")
    return
  end

  local pop_bufnr = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(pop_bufnr, 0, -1, { ctx.text })
  vim.bo[pop_bufnr].buftype = "acwrite" -- so :w fires BufWriteCmd
  vim.bo[pop_bufnr].swapfile = false
  vim.api.nvim_buf_set_name(pop_bufnr, "organ-cell://" .. tostring(src_line))

  local width = math.max(40, math.min(vim.fn.strdisplaywidth(ctx.text) + 8, vim.o.columns - 8))
  local win = vim.api.nvim_open_win(pop_bufnr, true, {
    relative = "editor",
    width = width,
    height = 5,
    row = math.floor((vim.o.lines - 5) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
    title = " edit cell ",
    title_pos = "center",
  })

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  local function do_commit()
    local lines = vim.api.nvim_buf_get_lines(pop_bufnr, 0, -1, false)
    commit(src_bufnr, ctx, table.concat(lines, "\n"))
    vim.bo[pop_bufnr].modified = false
  end

  vim.api.nvim_buf_set_keymap(pop_bufnr, "n", "<CR>", "", {
    noremap = true,
    silent = true,
    callback = function()
      do_commit()
      close()
    end,
    desc = "Commit cell edit",
  })
  vim.api.nvim_buf_set_keymap(pop_bufnr, "n", "q", "", {
    noremap = true,
    silent = true,
    callback = close,
    desc = "Cancel cell edit",
  })

  -- :w writes via BufWriteCmd → commit; :q!/:bd close.
  require("organ.errors").autocmd("BufWriteCmd", {
    buffer = pop_bufnr,
    callback = function()
      do_commit()
    end,
  })
  require("organ.errors").autocmd("BufWipeout", {
    buffer = pop_bufnr,
    once = true,
    callback = function() end,
  })
end

M.commands = {
  ["table edit_field"] = {
    fn = function()
      M.open()
    end,
    desc = "Edit the cell at cursor in a floating popup (Emacs C-c `)",
  },
}

return M
