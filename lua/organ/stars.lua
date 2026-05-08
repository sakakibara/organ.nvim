-- Hide leading stars on headings (Emacs `org-hide-leading-stars`).
--
-- Renders `*** Foo` as `  * Foo` by concealing the leading N-1 stars
-- with a space-replacement conceal extmark. The trailing star (the
-- one immediately before the title) stays visible so the depth marker
-- isn't lost entirely.
--
-- Off by default; opt in via `config.stars.hide = true`.
--
-- Implementation: iterate headline nodes from the org parser, place
-- one extmark per leading star. Re-applies on TextChanged + BufWinEnter
-- (cheap because we walk only headline nodes, not the whole buffer).
-- Concealment is visible only when `conceallevel >= 2` — we set the
-- window option to 2 on attach and restore on detach.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_stars_hide")

local function clear(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

-- Cached query (parsed once per session).
local _q
local function get_query()
  if _q then
    return _q
  end
  local ok, parsed = pcall(vim.treesitter.query.parse, "org", "(headline) @h")
  if ok then
    _q = parsed
  end
  return _q
end

local function apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  clear(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return
  end
  local tree = parser:parse()[1]
  if not tree then
    return
  end
  local q = get_query()
  if not q then
    return
  end

  -- Use a TS query to find every headline node — node:iter_children is
  -- depth-1 only, and the org grammar nests headlines under their
  -- parent's `section` so a recursive walk would miss them too.
  for _, node in q:iter_captures(tree:root(), bufnr, 0, -1) do
    local sr, sc = node:start()
    local ok_line, line = pcall(vim.api.nvim_buf_get_lines, bufnr, sr, sr + 1, false)
    if ok_line and line and line[1] then
      local stars = line[1]:match("^(%*+)") or ""
      local n = #stars
      if n > 1 then
        for i = 0, n - 2 do
          pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, sr, sc + i, {
            end_col = sc + i + 1,
            conceal = " ",
          })
        end
      end
    end
  end
end

-- Per-window saved conceallevel so detach() restores rather than nukes.
M._saved_conceallevel = M._saved_conceallevel or {}

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  -- Window-local (not buffer-local) — conceallevel is a window option.
  -- Save the current value so detach can restore it.
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] == nil then
    M._saved_conceallevel[winid] = vim.wo.conceallevel
  end
  if vim.wo.conceallevel < 2 then
    vim.wo.conceallevel = 2
  end

  apply(bufnr)
  local group = vim.api.nvim_create_augroup("organ_stars_" .. bufnr, { clear = true })
  local trigger = require("organ.debounce").trailing(150, function(b)
    if vim.api.nvim_buf_is_valid(b) then
      apply(b)
    end
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      trigger(bufnr)
    end,
  })
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  clear(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "organ_stars_" .. bufnr)
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] ~= nil then
    vim.wo.conceallevel = M._saved_conceallevel[winid]
    M._saved_conceallevel[winid] = nil
  end
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { limit = 1 })
  if #marks > 0 then
    M.detach(bufnr)
    return false
  end
  M.attach(bufnr)
  return true
end

M._apply = apply

return M
