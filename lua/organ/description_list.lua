-- Description-list separator highlighter.
--
-- Emacs renders `- term :: definition` with the term in a distinct
-- face and the `::` separator highlighted.  The org-grammar wraps
-- everything after the bullet in a single `(paragraph)` node, so
-- we can't capture term / `::` / definition via a tree-sitter
-- query alone.  This module walks list_item nodes and emits per-
-- range extmarks for the term + separator on lines that match
-- the `term :: definition` shape.
--
-- Runs as an `organ.decoration` provider: `on_win` walks the
-- tree-sitter tree for visible rows and builds a module-local
-- frame-row -> term/separator-span map; `on_line` reads from that
-- map and emits ephemeral hl extmarks for the current row.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_description_list")

-- Frame-local row map: frame_map[row] = {
--   term_start, term_end, sep_start, sep_end
-- }.  Reset at the start of every on_win call; read by on_line for
-- the same frame.  No per-buffer keying: only one window's on_win
-- runs before its on_line callbacks for the same frame.
local frame_map = {}

local function on_win(bufnr, _winid, topline, botline)
  frame_map = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  if require("organ.buf_config").read(bufnr, "description_list.enabled") == false then
    return
  end
  -- Tree is parsed once per buffer per redraw by organ.decoration; we
  -- just query the cached tree here.
  local tree = require("organ.decoration").get_tree(bufnr)
  if not tree then
    return
  end

  local function walk(node)
    local nsr, _, ner, _ = node:range()
    if ner < topline or nsr > botline then
      return
    end
    if node:type() == "list_item" then
      for c in node:iter_children() do
        if c:type() == "paragraph" then
          local sr, _, _, _ = c:range()
          if sr >= topline and sr <= botline then
            local lines = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)
            local body = lines[1] or ""
            -- Strip leading bullet + checkbox + whitespace so we match
            -- against the prose start.  Emacs requires `::` be surrounded
            -- by whitespace; we mirror that to avoid catching `https://`
            -- or `C++::std`.
            local prose_start, _ = body:find("[^%s%-%+%*%d%.%)]")
            if prose_start then
              local sep_a, _ = body:find("%s::%s", prose_start, false)
              if sep_a then
                frame_map[sr] = {
                  term_start = prose_start - 1,
                  term_end = sep_a - 1,
                  sep_start = sep_a,
                  sep_end = sep_a + 2,
                }
              end
            end
          end
          break
        end
      end
    end
    for c in node:iter_children() do
      walk(c)
    end
  end
  walk(tree:root())
end

local function on_line(bufnr, _winid, row)
  local entry = frame_map[row]
  if not entry then
    return
  end
  if entry.term_end > entry.term_start then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, entry.term_start, {
      end_col = entry.term_end,
      hl_group = "@org.list.term",
      ephemeral = true,
    })
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, entry.sep_start, {
    end_col = entry.sep_end,
    hl_group = "@org.list.term_separator",
    ephemeral = true,
  })
end

require("organ.decoration").register({
  name = "description_list",
  ns = NS,
  enabled = function(bufnr)
    -- No explicit config flag historically; on by default.  Honor an
    -- explicit `description_list.enabled = false` opt-out.
    return require("organ.buf_config").read(bufnr, "description_list.enabled") ~= false
  end,
  on_win = on_win,
  on_line = on_line,
})

-- Test-facing + ftplugin entrypoint.  Drive on_win across the full
-- buffer and place non-ephemeral extmarks so callers asserting via
-- `nvim_buf_get_extmarks` see them without waiting for a frame.
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local n = vim.api.nvim_buf_line_count(bufnr)
  on_win(bufnr, 0, 0, n - 1)
  for row, entry in pairs(frame_map) do
    if entry.term_end > entry.term_start then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, entry.term_start, {
        end_col = entry.term_end,
        hl_group = "@org.list.term",
      })
    end
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, entry.sep_start, {
      end_col = entry.sep_end,
      hl_group = "@org.list.term_separator",
    })
  end
end

M._frame_map = function()
  return frame_map
end

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(function()
    require("organ.decoration").attach(bufnr)
  end)
  M._apply(bufnr)
end

function M.detach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

-- Reapply hook: react to live `description_list.enabled` flips on this buffer.
require("organ.buf_config").on_reapply(function(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return
  end
  local want = require("organ.buf_config").read(bufnr, "description_list.enabled") ~= false
  if want then
    M.attach(bufnr)
  else
    M.detach(bufnr)
  end
end)

return M
