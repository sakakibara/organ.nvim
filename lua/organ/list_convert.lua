-- List <-> subtree conversion. Mirrors Emacs `org-list-make-subtree` and
-- `org-toggle-item` (C-c -).
--
-- list_to_subtree(opts)
--   Convert the contiguous list block at `opts.line` into a subtree of
--   headlines rooted at the level of the nearest enclosing headline + 1.
--   A checkbox becomes a keyword: `[X]` -> DONE, `[ ]` / `[-]` -> TODO.
--
-- toggle_item(opts)
--   A list item becomes plain text (the bullet goes, the indent stays).
--   A headline becomes a `- ` item: its TODO keyword turns into a
--   checkbox, and its tags, planning and property drawer are dropped.
--   Any other text line becomes a `- ` item at its own indent.

local M = {}

local obuf = require("organ.buf")
local list = require("organ.list")

local function is_item(line)
  return list.parse_item(line or "") ~= nil
end

local function is_headline(line)
  return (line or ""):match("^%*+%s") ~= nil
end

local function nearest_headline_level(lines, lnum)
  for i = lnum - 1, 1, -1 do
    local stars = (lines[i] or ""):match("^(%*+)%s")
    if stars then
      return #stars
    end
  end
  return 0
end

local function list_block(lines, lnum)
  if not is_item(lines[lnum]) then
    return nil
  end
  local indent = (lines[lnum] or ""):match("^(%s*)") or ""
  local center = #indent
  local s, e = lnum, lnum
  for i = lnum - 1, 1, -1 do
    if is_item(lines[i]) then
      local ind = #((lines[i] or ""):match("^(%s*)") or "")
      if ind <= center then
        s = i
      end
      if ind < center then
        break
      end
    else
      break
    end
  end
  for i = lnum + 1, #lines do
    if is_item(lines[i]) then
      local ind = #((lines[i] or ""):match("^(%s*)") or "")
      if ind >= center then
        e = i
      else
        break
      end
    else
      break
    end
  end
  return s, e
end

-- Emacs `org-list-to-subtree`: `:cbon "DONE " :cboff "TODO " :cbtrans "TODO "`.
local CHECKBOX_KEYWORD = { [" "] = "TODO ", X = "DONE ", x = "DONE ", ["-"] = "TODO " }

local function headline_title(item)
  local box, body = item.content:match("^%[([ Xx%-])%]%s*(.*)$")
  if box then
    return CHECKBOX_KEYWORD[box] .. body
  end
  return item.content
end

-- Convert the list block at `opts.line` into a subtree. Each top-level item
-- becomes a sibling headline; each nested item becomes a deeper headline.
-- `opts.bufnr` and `opts.line` default to current buffer + cursor line.
function M.list_to_subtree(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local lnum = opts.line or vim.fn.line(".")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s, e = list_block(lines, lnum)
  if not s then
    return nil, "no list at cursor"
  end
  local base_level = nearest_headline_level(lines, s) + 1
  -- Map item indent -> relative depth (0..N) so nested items become deeper headlines.
  local depths = {} -- ordered set of indent values present
  local seen = {}
  for i = s, e do
    local item = list.parse_item(lines[i])
    if item and not seen[#item.indent] then
      seen[#item.indent] = true
      depths[#depths + 1] = #item.indent
    end
  end
  table.sort(depths)
  local indent_to_depth = {}
  for di, ind in ipairs(depths) do
    indent_to_depth[ind] = di - 1
  end

  local out = {}
  for i = s, e do
    local item = list.parse_item(lines[i])
    if item then
      local depth = indent_to_depth[#item.indent]
      out[#out + 1] = string.rep("*", base_level + depth) .. " " .. headline_title(item)
    else
      -- Continuation line: keep the body, dedent if possible.
      out[#out + 1] = (lines[i] or ""):gsub("^%s+", "")
    end
  end
  obuf.set_lines(bufnr, s - 1, e, out)
  return e - s + 1
end

local function split_trailing_tags(s)
  local body = s:match("^(.-)%s+:[%w_@#%%][%w_@#%%:]*:%s*$")
  return body or s
end

-- Emacs `org-toggle-item` on a heading: stars and TODO keyword go (a
-- keyword leaves a `[ ]` / `[X]` checkbox behind), tags, planning and
-- the property drawer are deleted along with the blank lines after
-- them, and the item sits flush left unless `indent.adapt_indentation`
-- is on, where it takes the previous heading's text column.
local function headline_to_item(bufnr, lnum, line)
  local todo = require("organ.todo")
  local sequences = todo.effective_sequences(bufnr)
  local body = line:match("^%*+%s*(.*)$")
  local keyword
  local first, rest = body:match("^(%S+)%s*(.*)$")
  if first and vim.tbl_contains(todo.all_keywords(sequences), first) then
    keyword, body = first, rest
  end
  body = split_trailing_tags(body):gsub("%s+$", "")
  local box = ""
  if keyword then
    box = todo._is_done(keyword, sequences) and "[X] " or "[ ] "
  end

  local start_ind = 0
  if (require("organ.buf_config").read(bufnr, "indent") or {}).adapt_indentation then
    for i = lnum - 1, 1, -1 do
      local stars = (vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""):match("^(%*+)%s")
      if stars then
        start_ind = #stars + 1
        break
      end
    end
  end

  local element = require("organ.element")
  local meta_end = element.planning_end_line(bufnr, lnum - 1) - 1
  local drawer = element.property_drawer_range(bufnr, lnum - 1)
  if drawer then
    meta_end = drawer.end_line
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  while
    meta_end < total
    and (vim.api.nvim_buf_get_lines(bufnr, meta_end, meta_end + 1, false)[1] or ""):match("^%s*$")
  do
    meta_end = meta_end + 1
  end
  obuf.set_lines(bufnr, lnum - 1, meta_end, { string.rep(" ", start_ind) .. "- " .. box .. body })
end

-- Emacs `org-toggle-item` on a single line: item -> text, heading ->
-- item, text -> item.  Returns "to_text" / "to_item", or nil plus a
-- reason when the line is blank.
-- `opts.bufnr` and `opts.line` default to current buffer + cursor line.
function M.toggle_item(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local lnum = opts.line or vim.fn.line(".")
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""

  local item = list.parse_item(line)
  if item then
    obuf.set_lines(bufnr, lnum - 1, lnum, { item.indent .. item.content })
    return "to_text"
  end

  if is_headline(line) then
    headline_to_item(bufnr, lnum, line)
    return "to_item"
  end

  local indent, text = line:match("^(%s*)(%S.*)$")
  if not indent then
    return nil, "nothing to toggle on a blank line"
  end
  obuf.set_lines(bufnr, lnum - 1, lnum, { indent .. "- " .. text })
  return "to_item"
end

-- Emacs `org-toggle-heading` (C-c *) on a single line: an item or plain
-- line becomes a headline one level below the nearest headline above
-- (a checkbox turns into a TODO/DONE keyword); a headline becomes plain
-- text with its stars removed.  Returns "to_headline" / "to_text", or
-- nil plus a reason when the line is blank.
-- `opts.bufnr` and `opts.line` default to current buffer + cursor line.
function M.toggle_heading(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local lnum = opts.line or vim.fn.line(".")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line = lines[lnum] or ""

  if is_headline(line) then
    obuf.set_lines(bufnr, lnum - 1, lnum, { line:match("^%*+%s+(.*)$") or "" })
    return "to_text"
  end

  local item = list.parse_item(line)
  local text = item and headline_title(item) or line:match("^%s*(%S.*)$")
  if not text then
    return nil, "nothing to toggle on a blank line"
  end
  local level = nearest_headline_level(lines, lnum) + 1
  obuf.set_lines(bufnr, lnum - 1, lnum, { string.rep("*", level) .. " " .. text })
  return "to_headline"
end

M.commands = {
  toggle_heading = {
    fn = function()
      local kind, err = M.toggle_heading()
      if not kind then
        require("organ.notify").warn(tostring(err))
      end
    end,
    desc = "Make the line a headline, or a headline plain text (Emacs org-toggle-heading, C-c *)",
  },
  ["list to_subtree"] = {
    fn = function()
      local n, err = M.list_to_subtree()
      if not n then
        require("organ.notify").warn(tostring(err))
        return
      end
      require("organ.notify").info(("converted %d list line(s) to subtree"):format(n))
    end,
    desc = "Convert the list at cursor into headlines + sub-headlines",
  },
  toggle_item = {
    fn = function()
      local kind, err = M.toggle_item()
      if not kind then
        require("organ.notify").warn(tostring(err))
      end
    end,
    desc = "Make the line a list item, or an item plain text (Emacs org-toggle-item, C-c -)",
  },
}

return M
