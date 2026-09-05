-- lua/organ/clipboard.lua
-- :Org cut_subtree / :Org copy_subtree / :Org paste_subtree with re-leveling.
-- Module-local clipboard keeps org subtrees separate from Vim's yank ring.

local M = {}

local obuf = require("organ.buf")
-- Module-local clipboard.
local _lines = nil -- list of line strings
local _top_level = nil -- integer: the heading level of the top headline

-- Parse the level of a headline line. Returns integer or nil.
local function headline_level(text)
  local stars = text:match("^(%*+) ")
  if not stars then
    -- bare "*...\n" with no space after
    stars = text:match("^(%*+)$")
  end
  return stars and #stars or nil
end

-- Re-level a list of lines so that the top headline becomes `new_top_level`.
-- All nested headlines are shifted by the same delta.
-- Returns a new list of strings.
local function relevel(lines, old_top, new_top)
  if old_top == new_top then
    return lines
  end
  local delta = new_top - old_top
  local out = {}
  for _, l in ipairs(lines) do
    local lvl = headline_level(l)
    if lvl then
      local new_lvl = lvl + delta
      if new_lvl < 1 then
        new_lvl = 1
      end
      -- Preserve everything after the stars.
      local rest = l:match("^%*+(.*)$") or ""
      out[#out + 1] = string.rep("*", new_lvl) .. rest
    else
      out[#out + 1] = l
    end
  end
  return out
end

-- Copy the subtree containing `line` from `bufnr` into the module clipboard.
-- Returns err or nil.
function M.copy(bufnr, line)
  local structure = require("organ.structure")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  local subtree_end = structure._subtree_end(bufnr, hl)
  local lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, subtree_end, false)
  _lines = lines
  _top_level = hl.level
  return nil
end

-- Cut the subtree containing `line` from `bufnr` into the module clipboard.
-- Deletes those lines from the buffer. Returns err or nil.
function M.cut(bufnr, line)
  local structure = require("organ.structure")
  local hl = structure._find_containing_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  local subtree_end = structure._subtree_end(bufnr, hl)
  local lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, subtree_end, false)
  _lines = lines
  _top_level = hl.level
  -- Delete the lines from the buffer.
  obuf.set_lines(bufnr, hl.line - 1, subtree_end, {})
  pcall(function()
    require("organ.spacing").normalize_at_cut(bufnr, hl.line)
  end)
  return nil
end

-- Paste the clipboard below `line` in `bufnr`, re-leveling so the pasted top
-- headline becomes the child of the headline at cursor (cursor_level + 1).
-- If cursor is on a headline of level N → paste at N+1.
-- If cursor is on body text, find the containing headline at level N → paste at N+1.
-- Returns err or nil.
function M.paste(bufnr, line)
  if not _lines or #_lines == 0 then
    return "clipboard is empty"
  end

  local structure = require("organ.structure")

  -- Determine where to insert: find the containing headline to get its level.
  local cursor_level

  local line_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local direct_level = headline_level(line_text)
  if direct_level then
    cursor_level = direct_level
  else
    local hl = structure._find_containing_headline(bufnr, line)
    if hl then
      cursor_level = hl.level
    else
      cursor_level = 0 -- top level; paste as level 1
    end
  end

  local target_level = cursor_level + 1
  if target_level < 1 then
    target_level = 1
  end

  -- Re-level clipboard lines.
  local pasted = relevel(_lines, _top_level, target_level)

  -- Find the subtree end of the headline at cursor (or of the containing
  -- headline if on body text) to insert *after* the whole subtree.
  local insert_after
  if direct_level then
    -- Cursor is on a headline: insert after its subtree.
    local fake_hl = { line = line, level = direct_level }
    insert_after = structure._subtree_end(bufnr, fake_hl)
  else
    -- Cursor on body text: insert after the cursor line itself.
    insert_after = line
  end

  obuf.set_lines(bufnr, insert_after, insert_after, pasted)
  pcall(function()
    require("organ.spacing").normalize_around(bufnr, insert_after + 1)
  end)
  return nil
end

-- Expose clipboard state for tests.
function M._get_clipboard()
  return _lines, _top_level
end

local function notify_info(msg)
  if require("organ.buf_config").read(nil, "notify") then
    require("organ.errors").schedule("organ.clipboard", function()
      require("organ.notify").info(msg)
    end)
  end
end

M.commands = {
  cut_subtree = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local err = M.cut(bufnr, line)
      if err then
        require("organ.notify").warn(err)
      end
    end,
    desc = "Cut the subtree at cursor into the organ clipboard",
  },
  copy_subtree = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local err = M.copy(bufnr, line)
      if err then
        require("organ.notify").warn(err)
      else
        notify_info("subtree copied")
      end
    end,
    desc = "Copy the subtree at cursor into the organ clipboard",
  },
  paste_subtree = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local err = M.paste(bufnr, line)
      if err then
        require("organ.notify").warn(err)
      end
    end,
    desc = "Paste the organ clipboard subtree below cursor (with re-leveling)",
  },
}

return M
