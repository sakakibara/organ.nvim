-- Hide leading stars on headings (Emacs `org-hide-leading-stars`).
--
-- Renders `*** Foo` as `  * Foo` by concealing the leading N-1 stars
-- with a space-replacement conceal extmark.  The trailing star (the
-- one immediately before the title) stays visible so the depth marker
-- isn't lost entirely.
--
-- Off by default; opt in via `config.stars.hide = true`.
--
-- Runs as an `organ.decoration` provider: `on_win` scans rows in the
-- visible window range with a leading-`(%*+)%s` regex and builds a
-- module-local frame-row -> star-count map.  Regex (rather than
-- tree-sitter) is the right tool here: counting leading stars on a
-- headline is a flat byte-prefix check that doesn't benefit from
-- node-level scoping.  `on_line` reads the map and emits conceal
-- extmarks for the current row.  Concealment is visible only when
-- `conceallevel >= 2` -- `attach()` bumps it to 2 (restored by detach).

local M = {}

local NS = vim.api.nvim_create_namespace("organ_stars_hide")

-- Per-window saved conceallevel so detach() restores rather than nukes.
M._saved_conceallevel = M._saved_conceallevel or {}

-- Frame-local row map: frame_map[row] = leading-star count (>= 2).
-- Reset at the start of every on_win call; read by on_line for the
-- same frame.  No per-buffer keying: only one window's on_win runs
-- before its on_line callbacks for the same frame.
local frame_map = {}

local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "stars.hide") ~= true then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, topline, botline + 1, false)
  for i, line in ipairs(lines) do
    local stars = line:match("^(%*+)%s")
    if stars and #stars >= 2 then
      frame_map[topline + i - 1] = #stars
    end
  end
end

local function on_line(bufnr, winid, row)
  if vim.wo[winid].conceallevel == 0 then
    return
  end
  local n = frame_map[row]
  if not n or n < 2 then
    return
  end
  for i = 0, n - 2 do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, i, {
      end_col = i + 1,
      conceal = " ",
      ephemeral = true,
    })
  end
end

-- Display string that replaces a headline's leading `level`-star block:
-- (level-1) spaces + the trailing star.  Only levels >= 2 are concealed
-- (a level-1 `* ` keeps its single star), so level 1 returns nil = no
-- change.  Used by the foldtext renderer -- a closed fold renders
-- foldtext, which the on_line conceal never reaches.
function M.star_display(level)
  if not level or level < 2 then
    return nil
  end
  return string.rep(" ", level - 1) .. "*"
end

require("organ.decoration").register({
  name = "stars",
  ns = NS,
  enabled = function(bufnr)
    return require("organ.buf_config").read(bufnr, "stars.hide") == true
  end,
  on_win = on_win,
  on_line = on_line,
})

-- Test-facing: drive on_win across the full buffer and place
-- non-ephemeral extmarks so callers asserting via
-- `nvim_buf_get_extmarks` see them without waiting for a frame.
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  on_win(bufnr, 0, 0, n - 1)
  for row, count in pairs(frame_map) do
    for i = 0, count - 2 do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, i, {
        end_col = i + 1,
        conceal = " ",
      })
    end
  end
end

M._frame_map = function()
  return frame_map
end

-- Test-facing + ftplugin entrypoint.  Bumps the window's conceallevel
-- to 2 (saving the previous value), attaches the decoration provider
-- to the buffer, and synchronously applies non-ephemeral extmarks so
-- callers that assert via `nvim_buf_get_extmarks` see them without
-- waiting for a frame.
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] == nil then
    M._saved_conceallevel[winid] = vim.wo.conceallevel
  end
  if vim.wo.conceallevel < 2 then
    vim.wo.conceallevel = 2
  end
  pcall(function()
    require("organ.decoration").attach(bufnr)
  end)
  M._apply(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local winid = vim.api.nvim_get_current_win()
  if M._saved_conceallevel[winid] ~= nil then
    vim.wo.conceallevel = M._saved_conceallevel[winid]
    M._saved_conceallevel[winid] = nil
  end
end

function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local on = require("organ.buf_config").toggle(bufnr, "stars.hide")
  return on and true or false
end

-- Reapply hook: react to live `stars.hide` flips on this buffer.
require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local want = require("organ.buf_config").read(bufnr, "stars.hide") == true
  if want then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
