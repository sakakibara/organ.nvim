local M = {}

-- Parse a headline line. Returns { level = N, title_text = "..." } or nil.
local function parse_headline_line(text)
  local stars, rest = text:match("^(%*+)%s+(.*)$")
  if not stars then
    -- Could also be a bare "*+\n" with no title; tolerate but ignore.
    stars = text:match("^(%*+)$")
    if stars then
      return { level = #stars, title_text = "" }
    end
    return nil
  end
  return { level = #stars, title_text = rest }
end

-- Find the headline that contains the given 1-based line number.
-- Returns { line = N, level = L, title_text = "..." } or nil.
-- Uses the per-buffer element cache (changedtick-keyed) so repeated
-- motions on a large buffer are O(log H) instead of O(N).
function M._find_containing_headline(bufnr, line)
  local total = vim.api.nvim_buf_line_count(bufnr)
  if line < 1 or line > total then
    return nil
  end
  local entry = require("organ.element_cache").containing(bufnr, line)
  if entry then
    return { line = entry.line, level = entry.level, title_text = entry.title }
  end
  return nil
end

-- Find the last line included in the headline's subtree.
-- Subtree ends right before the next headline at the same or shallower level,
-- or at end of buffer.
function M._subtree_end(bufnr, headline)
  return require("organ.element_cache").subtree_end(bufnr, headline.line)
end

-- All headline lines (1-based) strictly between `from_line+1` and
-- `to_line` inclusive, with their levels.  TS-first via
-- `element.headlines`; regex fallback walks each line once.
local function collect_descendants(bufnr, from_line, to_line)
  local element = require("organ.element")
  local out = {}
  if element.parser_loaded(bufnr) then
    for _, h in ipairs(element.headlines(bufnr)) do
      local one_based = h.line_start + 1
      if one_based > from_line and one_based <= to_line then
        out[#out + 1] = { line = one_based, level = h.level }
      end
    end
    return out
  end
  for i = from_line + 1, to_line do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    local p = parse_headline_line(txt)
    if p then
      out[#out + 1] = { line = i, level = p.level }
    end
  end
  return out
end

-- Replace the leading run of "*+ " on a single line with a shorter run.
-- Returns nil on success or an error string.
local function rewrite_stars(bufnr, line, new_level)
  local txt = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local stars, rest = txt:match("^(%*+)(.*)$")
  if not stars then
    return "not a headline line"
  end
  local new_text = string.rep("*", new_level) .. rest
  vim.api.nvim_buf_set_lines(bufnr, line - 1, line, false, { new_text })
  return nil
end

-- Resolve `(bufnr, line)` from an optional opts table.  Both keys default
-- to "current": `vim.api.nvim_get_current_buf()` and `vim.fn.line(".")`.
-- All public action functions in this module accept the same opts shape.
local function resolve(opts)
  opts = opts or {}
  return opts.bufnr or vim.api.nvim_get_current_buf(), opts.line or vim.fn.line(".")
end

function M.promote_headline(opts)
  local bufnr, line = resolve(opts)
  local hl = M._find_containing_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  if hl.level == 1 then
    return "cannot promote level-1 headline"
  end
  return rewrite_stars(bufnr, hl.line, hl.level - 1)
end

function M.promote_subtree(opts)
  local bufnr, line = resolve(opts)
  local hl = M._find_containing_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  if hl.level == 1 then
    return "cannot promote level-1 subtree"
  end
  local subtree_end = M._subtree_end(bufnr, hl)
  -- Collect headline lines in reverse order so set_lines mutations don't
  -- shift later indexes (each call replaces 1 line with 1 line — same length —
  -- but reverse order keeps the algorithm uniform across operations).
  local descendants = collect_descendants(bufnr, hl.line, subtree_end)
  -- Apply in reverse line order.
  for i = #descendants, 1, -1 do
    local d = descendants[i]
    rewrite_stars(bufnr, d.line, d.level - 1)
  end
  -- Then the current headline.
  rewrite_stars(bufnr, hl.line, hl.level - 1)
  return nil
end

function M.demote_headline(opts)
  local bufnr, line = resolve(opts)
  local hl = M._find_containing_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  if hl.level >= 9 then
    return "cannot demote past level 9"
  end
  return rewrite_stars(bufnr, hl.line, hl.level + 1)
end

function M.demote_subtree(opts)
  local bufnr, line = resolve(opts)
  local hl = M._find_containing_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  local subtree_end = M._subtree_end(bufnr, hl)
  -- Pre-flight: find deepest level in subtree.
  local deepest = hl.level
  local headlines = { { line = hl.line, level = hl.level } }
  for _, d in ipairs(collect_descendants(bufnr, hl.line, subtree_end)) do
    headlines[#headlines + 1] = d
    if d.level > deepest then
      deepest = d.level
    end
  end
  if deepest >= 9 then
    return "cannot demote past level 9"
  end
  -- Apply in forward line order; rewrite_stars preserves the line count
  -- (replace 1 line with 1 line) so indexes stay valid as we go.
  for _, h in ipairs(headlines) do
    rewrite_stars(bufnr, h.line, h.level + 1)
  end
  return nil
end

-- Find the previous sibling headline at the same level, or nil if none.
local function prev_sibling(bufnr, headline)
  for i = headline.line - 1, 1, -1 do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    local p = parse_headline_line(txt)
    if p then
      if p.level < headline.level then
        return nil
      end -- went into parent
      if p.level == headline.level then
        return { line = i, level = p.level }
      end
      -- deeper level — keep scanning (nested)
    end
  end
  return nil
end

-- Find the next sibling headline at the same level starting just past the
-- current subtree, or nil if none.
local function next_sibling(bufnr, headline)
  local subtree_end = M._subtree_end(bufnr, headline)
  local total = vim.api.nvim_buf_line_count(bufnr)
  for i = subtree_end + 1, total do
    local txt = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    local p = parse_headline_line(txt)
    if p then
      if p.level < headline.level then
        return nil
      end
      if p.level == headline.level then
        return { line = i, level = p.level }
      end
    end
  end
  return nil
end

function M.move_subtree_up(opts)
  local bufnr, line = resolve(opts)
  local hl = M._find_containing_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  local prev = prev_sibling(bufnr, hl)
  if not prev then
    return "no previous sibling"
  end
  local prev_hl = { line = prev.line, level = prev.level }
  local prev_end = M._subtree_end(bufnr, prev_hl)
  local cur_end = M._subtree_end(bufnr, hl)
  -- Read both blocks.
  local prev_lines = vim.api.nvim_buf_get_lines(bufnr, prev.line - 1, prev_end, false)
  local cur_lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, cur_end, false)
  -- Replace [prev.line, cur_end] with cur_lines ++ prev_lines (single atomic call).
  local combined = {}
  for _, l in ipairs(cur_lines) do
    combined[#combined + 1] = l
  end
  for _, l in ipairs(prev_lines) do
    combined[#combined + 1] = l
  end
  vim.api.nvim_buf_set_lines(bufnr, prev.line - 1, cur_end, false, combined)
  return nil
end

function M.move_subtree_down(opts)
  local bufnr, line = resolve(opts)
  local hl = M._find_containing_headline(bufnr, line)
  if not hl then
    return "not on a headline"
  end
  local nxt = next_sibling(bufnr, hl)
  if not nxt then
    return "no next sibling"
  end
  local nxt_hl = { line = nxt.line, level = nxt.level }
  local nxt_end = M._subtree_end(bufnr, nxt_hl)
  local cur_end = M._subtree_end(bufnr, hl)
  local cur_lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, cur_end, false)
  local nxt_lines = vim.api.nvim_buf_get_lines(bufnr, nxt.line - 1, nxt_end, false)
  local combined = {}
  for _, l in ipairs(nxt_lines) do
    combined[#combined + 1] = l
  end
  for _, l in ipairs(cur_lines) do
    combined[#combined + 1] = l
  end
  vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, nxt_end, false, combined)
  return nil
end

local function run_op(name)
  local err = M[name]()
  if err then
    require("organ.notify").warn(err)
  end
end

M.commands = {
  promote = {
    fn = function()
      run_op("promote_subtree")
    end,
    desc = "Promote the subtree at cursor by one level (Emacs S-M-LEFT)",
  },
  demote = {
    fn = function()
      run_op("demote_subtree")
    end,
    desc = "Demote the subtree at cursor by one level (Emacs S-M-RIGHT)",
  },
  promote_headline = {
    fn = function()
      run_op("promote_headline")
    end,
    desc = "Promote just the current headline (NOT its children)",
  },
  demote_headline = {
    fn = function()
      run_op("demote_headline")
    end,
    desc = "Demote just the current headline (NOT its children)",
  },
  move_up = {
    fn = function()
      run_op("move_subtree_up")
    end,
    desc = "Swap the subtree at cursor with the previous same-level sibling (Emacs M-UP)",
  },
  move_down = {
    fn = function()
      run_op("move_subtree_down")
    end,
    desc = "Swap the subtree at cursor with the next same-level sibling (Emacs M-DOWN)",
  },
  inline_task_insert = {
    fn = function(cmd)
      local cfg = (require("organ").config.inlinetask or {})
      local level = cfg.min_level or 15
      local stars = string.rep("*", level)
      local title = (cmd and cmd.args and cmd.args ~= "") and cmd.args or "task"
      local block = { stars .. " " .. title, "", stars .. " END" }
      local bufnr = vim.api.nvim_get_current_buf()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      vim.api.nvim_buf_set_lines(bufnr, row, row, false, block)
      pcall(vim.api.nvim_win_set_cursor, 0, { row + 2, 0 })
    end,
    nargs = "?",
    desc = "Insert an inline task scaffold (Emacs C-c C-x t)",
  },
}

return M
