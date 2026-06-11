-- List ↔ subtree conversion. Mirrors Emacs `org-list-make-subtree` and
-- `org-toggle-item` (C-c -).
--
-- list_to_subtree(bufnr, line)
--   Convert the contiguous list block at `line` into a subtree of headlines
--   rooted at the level of the nearest enclosing headline + 1.
--
-- toggle_item(bufnr, line)
--   If the line is a list item → promote to a headline (level = nearest
--                                  parent + 1, default 1).
--   If the line is a headline → demote to a list item under the parent.
--   Other lines are left alone.

local M = {}

local obuf = require("organ.buf")
local function is_item(line)
  -- `* foo` at column 0 is a HEADLINE in org, not a list item. The `*`
  -- form is a bullet only when indented; `-` and `+` are unambiguous.
  if (line or ""):match("^%s+%*%s") then
    return true
  end
  if (line or ""):match("^%s*[%-%+]%s") then
    return true
  end
  if (line or ""):match("^%s*%d+[%.%)]%s") then
    return true
  end
  return false
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
    elseif (lines[i] or ""):match("^%s*$") then
      break
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
    elseif (lines[i] or ""):match("^%s*$") then
      break
    else
      break
    end
  end
  return s, e
end

-- Strip an item's bullet ("- ", "+ ", "* ", "1. ", "2) ") and any optional
-- `[X]` checkbox marker; returns (indent, bullet_kind, content). bullet_kind
-- is one of "unordered" / "ordered".
local function parse_item(line)
  local indent, bullet, rest = (line or ""):match("^(%s*)([%-%+%*])%s+(.*)$")
  if bullet then
    rest = rest:gsub("^%[[ Xx%-]%]%s*", "") -- drop checkbox if any
    return indent, "unordered", rest
  end
  local indent2, num, rest2 = (line or ""):match("^(%s*)(%d+)[%.%)]%s+(.*)$")
  if num then
    rest2 = rest2:gsub("^%[[ Xx%-]%]%s*", "")
    return indent2, "ordered", rest2
  end
  return nil
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
  -- Map item-indent → relative depth (0..N) so nested items become deeper headlines.
  local depths = {} -- ordered set of indent values present
  local seen = {}
  for i = s, e do
    if is_item(lines[i]) then
      local ind = #((lines[i] or ""):match("^(%s*)") or "")
      if not seen[ind] then
        seen[ind] = true
        depths[#depths + 1] = ind
      end
    end
  end
  table.sort(depths)
  local indent_to_depth = {}
  for di, ind in ipairs(depths) do
    indent_to_depth[ind] = di - 1
  end

  local out = {}
  for i = s, e do
    local ln = lines[i]
    if is_item(ln) then
      local indent, _, content = parse_item(ln)
      local depth = indent_to_depth[#indent]
      out[#out + 1] = string.rep("*", base_level + depth) .. " " .. (content or "")
    else
      -- Continuation line: keep the body, dedent if possible.
      out[#out + 1] = (ln or ""):gsub("^%s+", "")
    end
  end
  obuf.set_lines(bufnr, s - 1, e, out)
  return e - s + 1
end

-- Toggle: list item → headline, OR headline → list item (under parent).
-- `opts.bufnr` and `opts.line` default to current buffer + cursor line.
function M.toggle_item(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local lnum = opts.line or vim.fn.line(".")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local line = lines[lnum] or ""

  if is_item(line) then
    local _, _, content = parse_item(line)
    local level = nearest_headline_level(lines, lnum) + 1
    local new = string.rep("*", level) .. " " .. (content or "")
    obuf.set_lines(bufnr, lnum - 1, lnum, { new })
    return "to_headline"
  end

  if is_headline(line) then
    local _, content = line:match("^(%*+)%s+(.*)$")
    -- Indent: 2 spaces per level above 1 (so `**` becomes "  - ").
    local stars = line:match("^(%*+)") or "*"
    local indent = string.rep("  ", math.max(0, #stars - 1))
    local new = indent .. "- " .. (content or "")
    obuf.set_lines(bufnr, lnum - 1, lnum, { new })
    return "to_item"
  end

  return nil, "no list item or headline at cursor"
end

M.commands = {
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
    desc = "Toggle list item <-> headline at cursor (Emacs C-c -)",
  },
}

return M
