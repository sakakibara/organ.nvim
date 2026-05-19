-- Single-keystroke popup menu used by `:Org agenda` dispatcher
-- and `:Org todo`'s fast-pick.  Blocks on `getcharstr` until the
-- user types a key, so the menu STAYS UP regardless of what other
-- async UI plugins (noice, snacks, completion) do.  Going through
-- `nvim_echo` instead would let those routes intercept / overdraw
-- the prompt mid-wait.
--
-- Caller passes `entries` shaped as a list of `{ key, label,
-- action }` (action is whatever the caller wants the matched key
-- to dispatch to -- typically a function).  Returns
-- `(matched_action_or_nil, char_or_nil)`:
--   - both nil when the user cancelled (Esc / Ctrl-C / unmapped)
--   - action nil + char set when the user pressed an unmapped key
--   - both set when the user picked a known entry

local M = {}

local obuf = require("organ.buf")

--- @param entries table  list of `{ key, label, action }` triples
--- @param opts? table    { title?: string, prompt?: string }
--- @return any|nil       the matched entry's `action`, nil on
---                       cancel / unmatched key
--- @return string|nil    the keystroke entered, nil on cancel
function M.pick(entries, opts)
  opts = opts or {}
  local prompt = opts.prompt or "Press key:"
  local title = opts.title

  local lines = { prompt, "" }
  for _, e in ipairs(entries) do
    lines[#lines + 1] = string.format("  %s   %s", e[1], e[2])
  end

  local width = 0
  for _, l in ipairs(lines) do
    if #l > width then
      width = #l
    end
  end
  width = math.max(width + 2, #(title or "") + 4)
  local height = #lines

  local bufnr = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(bufnr, 0, -1, lines)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false

  local row = math.max(0, math.floor((vim.o.lines - height) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local win = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = "rounded",
    style = "minimal",
    title = title and (" " .. title .. " ") or nil,
    title_pos = title and "center" or nil,
    noautocmd = true,
  })

  -- Force a redraw so the popup is visible before getcharstr blocks.
  pcall(vim.cmd, "redraw")
  local ok, char = pcall(vim.fn.getcharstr)
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.cmd, "redraw")

  if not ok or not char or char == "" then
    return nil, nil
  end
  for _, e in ipairs(entries) do
    if e[1] == char then
      return e[3], char
    end
  end
  return nil, char
end

return M
