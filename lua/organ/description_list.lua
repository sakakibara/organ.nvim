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
-- Buffer-attached service: M.attach(bufnr) installs an autocmd
-- that re-applies marks on TextChanged + TextChangedI.

local M = {}

local NS = vim.api.nvim_create_namespace("organ_description_list")

local function clear(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, NS, 0, -1)
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
  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return
  end

  local function walk(node)
    if node:type() == "list_item" then
      -- The list_item's first paragraph child carries the body
      -- text.  We only check the FIRST line of that paragraph for
      -- the `term :: definition` shape — multi-line definitions
      -- are still recognized but only the term line gets the
      -- separator highlight.
      for c in node:iter_children() do
        if c:type() == "paragraph" then
          local sr, _, _, _ = c:range()
          local lines = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)
          local body = lines[1] or ""
          -- Strip leading bullet + checkbox + whitespace so we
          -- match against the prose start.  Emacs requires `::`
          -- be surrounded by whitespace; we mirror that to avoid
          -- catching `https://` or `C++::std`.
          local prose_start, _ = body:find("[^%s%-%+%*%d%.%)]")
          if prose_start then
            local sep_a, sep_b = body:find("%s::%s", prose_start, false)
            if sep_a then
              -- Term: prose_start .. sep_a-1 (inclusive byte range).
              -- Separator: the `::` itself (sep_a+1 .. sep_a+2).
              local term_s = prose_start - 1 -- 0-based
              local term_e = sep_a - 1 -- 0-based exclusive
              if term_e > term_s then
                pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, sr, term_s, {
                  end_col = term_e,
                  hl_group = "@org.list.term",
                })
              end
              local sep_s = sep_a -- skip leading space
              pcall(vim.api.nvim_buf_set_extmark, bufnr, NS, sr, sep_s, {
                end_col = sep_s + 2,
                hl_group = "@org.list.term_separator",
              })
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

function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  apply(bufnr)
  local group = vim.api.nvim_create_augroup("organ_desclist_" .. bufnr, { clear = true })
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
  pcall(vim.api.nvim_del_augroup_by_name, "organ_desclist_" .. bufnr)
end

M._apply = apply

return M
