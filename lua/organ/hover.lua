-- K-keymap hover: when cursor sits on a `[[link]]`, show a popup
-- with the target headline + first ~10 body lines. Falls through to
-- vim's default `K` (`:h K`) when not on a link, so users with a
-- shell help mapping (man pages etc.) keep their usual behavior.
--
-- Powers the LSP hover handler too — both routes here.

local M = {}

local function read_body_preview(file_path, line_start, max_lines)
  max_lines = max_lines or 10
  local f = io.open(file_path, "r")
  if not f then
    return nil
  end
  local out = {}
  local skipped = 0
  for ln in f:lines() do
    skipped = skipped + 1
    if skipped > line_start + 1 then
      if ln:match("^%*+%s") then
        break
      end
      out[#out + 1] = ln
      if #out >= max_lines then
        break
      end
    end
  end
  f:close()
  return out
end

-- Resolve the link body to a headline row (or nil).
function M.resolve(body)
  local q = require("organ.query")
  local id = body:match("^id:(.+)$")
  if id then
    local rows = q.headlines({ id = id })
    return rows and rows[1] or nil
  end
  local title = body:match("^%*(.+)$")
  if title then
    local rows = q.headlines({ title = title })
    return rows and rows[1] or nil
  end
  return nil
end

-- Build the markdown contents for a resolved headline.
function M.preview_lines(row)
  local lines = {}
  local hdr = string.format("**%s** %s", row.todo_state or "", row.title or "")
  lines[#lines + 1] = hdr
  lines[#lines + 1] =
    string.format("_%s:%d_", vim.fn.fnamemodify(row.file_path, ":~:."), (row.line_start or 0) + 1)
  local body = read_body_preview(row.file_path, row.line_start or 0, 10)
  if body and #body > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "```org"
    for _, b in ipairs(body) do
      lines[#lines + 1] = b
    end
    lines[#lines + 1] = "```"
  end
  return lines
end

-- Public: open the hover popup for the link under cursor. Returns
-- true when a popup opened, false (and falls through to default K)
-- otherwise.
--
-- When the in-process LSP server is attached to this buffer, defer to
-- the LSP `K` path (vim.lsp.buf.hover) so the LSP server's hover
-- handler — which is the same code by another route — gets to do its
-- thing AND the LSP client gets a chance to record the request.
function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local lsp_clients = vim.lsp.get_clients({ bufnr = bufnr, name = "organ" })
  if #lsp_clients > 0 then
    vim.lsp.buf.hover()
    return true
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local link = require("organ.element").link_at(bufnr, row - 1, col)
  if not link then
    return false
  end
  local target = M.resolve(link.target)
  if not target then
    return false
  end
  local md = M.preview_lines(target)
  vim.lsp.util.open_floating_preview(md, "markdown", {
    border = "rounded",
    focusable = true,
    close_events = { "CursorMoved", "BufHidden", "InsertEnter" },
  })
  return true
end

return M
