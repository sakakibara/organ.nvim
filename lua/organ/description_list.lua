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
-- Runs as an `organ.decoration` provider: `on_lines` rebuilds a
-- per-buffer row cache from the tree, and `on_line` emits ephemeral
-- extmarks for the visible row.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_description_list")

-- Per-buffer row cache: cache_by_buf[bufnr][row] = {
--   term_start, term_end, sep_start, sep_end
-- }.  Rows that don't match `term :: definition` are absent.
local cache_by_buf = {}

-- Walk list_item / paragraph nodes and bucket `term :: definition`
-- ranges by row.  The org-grammar wraps the list-item body in a
-- single `(paragraph)` node, so we inspect the first line of each
-- paragraph child of a list_item and apply the same byte-range
-- arithmetic the pre-migration apply() used.
local function build_cache(bufnr)
  local rows = {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return rows
  end
  if vim.bo[bufnr].filetype ~= "org" then
    return rows
  end
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  if not ok or not parser then
    return rows
  end
  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return rows
  end

  local function walk(node)
    if node:type() == "list_item" then
      for c in node:iter_children() do
        if c:type() == "paragraph" then
          local sr, _, _, _ = c:range()
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
              local term_s = prose_start - 1 -- 0-based
              local term_e = sep_a - 1 -- 0-based exclusive
              local sep_s = sep_a
              local sep_e = sep_a + 2
              rows[sr] = {
                term_start = term_s,
                term_end = term_e,
                sep_start = sep_s,
                sep_end = sep_e,
              }
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
  return rows
end

-- Emit the cached term + separator extmarks for one row.  Shared
-- between the ephemeral on_line path and the non-ephemeral _apply
-- path; `ephemeral` is set by the caller.
local function place_row(bufnr, row, entry, ephemeral)
  if entry.term_end > entry.term_start then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, entry.term_start, {
      end_col = entry.term_end,
      hl_group = "@org.list.term",
      ephemeral = ephemeral or nil,
    })
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, row, entry.sep_start, {
    end_col = entry.sep_end,
    hl_group = "@org.list.term_separator",
    ephemeral = ephemeral or nil,
  })
end

require("organ.decoration").register({
  name = "description_list",
  ns = NS,
  enabled = function(_bufnr)
    -- No explicit config flag historically; on by default.  Honor an
    -- explicit `description_list.enabled = false` opt-out.
    local cfg = require("organ").config
    local sub = cfg.description_list
    if sub == nil then
      return true
    end
    return sub.enabled ~= false
  end,
  on_lines = function(bufnr, _first, _last_old, _last_new)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    -- Full rebuild: tree-sitter incremental parse keeps the cost
    -- bounded; range-bounded walks are a future optimization.
    cache_by_buf[bufnr] = build_cache(bufnr)
  end,
  on_line = function(bufnr, _winid, row)
    local rows = cache_by_buf[bufnr]
    if not rows then
      return
    end
    local entry = rows[row]
    if not entry then
      return
    end
    place_row(bufnr, row, entry, true)
  end,
})

-- Test-facing + ftplugin entrypoint.  Rebuild the cache + place
-- non-ephemeral extmarks so callers asserting via
-- `nvim_buf_get_extmarks` see them without waiting for a frame.
function M._apply(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
  local rows = build_cache(bufnr)
  cache_by_buf[bufnr] = rows
  for row, entry in pairs(rows) do
    place_row(bufnr, row, entry, false)
  end
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
  cache_by_buf[bufnr] = nil
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
end

return M
