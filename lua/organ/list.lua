-- List operations: repair (re-sequence numbered items), sort, counter
-- handling for `[@N]` start markers.
--
-- A "list" is a contiguous block of org list items at the same indent level.
-- We work line-by-line — no tree-sitter dependency — so editing buffers in
-- progress is safe. Nested sub-lists are left untouched (caller decides what
-- to do with deeper levels).

local M = {}

local obuf = require("organ.buf")
-- Parse one line into { indent, bullet, counter, content } or nil.
--   indent  = leading whitespace string
--   bullet  = "-" / "+" / "*" (unordered) OR "1." / "2)" (ordered)
--   counter = numeric value of an ordered bullet, or nil for unordered
--   content = the body after the bullet
function M.parse_item(line)
  local indent, bullet, content = line:match("^(%s*)([%-%+%*])%s+(.*)$")
  if bullet then
    return { indent = indent, bullet = bullet, content = content }
  end
  local i, num, sep, c = line:match("^(%s*)(%d+)([.)])%s+(.*)$")
  if num then
    return {
      indent = i,
      bullet = num .. sep,
      counter = tonumber(num),
      sep = sep,
      content = c,
    }
  end
  return nil
end

-- Find the contiguous list block (range of 1-based line indices) containing
-- the line at `cursor_line`. The block is scanned only at the cursor's
-- indent level — items at deeper indents are accepted as continuations,
-- items at shallower indents end the block.
function M.block_at(bufnr, cursor_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local center = M.parse_item(lines[cursor_line] or "")
  if not center then
    return nil
  end
  local center_indent = #center.indent

  local s, e = cursor_line, cursor_line
  -- Walk up: include items at >= center_indent until we hit non-item / shallower.
  for i = cursor_line - 1, 1, -1 do
    local p = M.parse_item(lines[i] or "")
    if p and #p.indent >= center_indent then
      s = i
    elseif (lines[i] or ""):match("^%s*$") then
      -- blank line breaks a list
      break
    else
      break
    end
  end
  for i = cursor_line + 1, #lines do
    local p = M.parse_item(lines[i] or "")
    if p and #p.indent >= center_indent then
      e = i
    elseif (lines[i] or ""):match("^%s*$") then
      break
    else
      break
    end
  end
  return s, e, center_indent
end

-- Repair: re-sequence numbered items at the cursor's indent level. Honors
-- `[@N]` counter override on the first item — subsequent items follow.
-- Unordered bullets and items at deeper indents are left alone.
function M.repair(bufnr, cursor_line)
  local s, e, indent = M.block_at(bufnr, cursor_line)
  if not s then
    return 0
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local n_changed = 0

  -- Find the starting counter: explicit `[@N]` override on the first
  -- top-level numbered item, else 1.
  local counter
  for i, ln in ipairs(lines) do
    local p = M.parse_item(ln)
    if p and #p.indent == indent and p.counter then
      local override = p.content:match("^%[@(%d+)%]")
      counter = tonumber(override) or 1
      _ = i
      break
    end
  end
  if not counter then
    return 0
  end -- no ordered items to repair

  for i, ln in ipairs(lines) do
    local p = M.parse_item(ln)
    if p and #p.indent == indent and p.counter then
      local desired = tostring(counter) .. p.sep
      if p.bullet ~= desired then
        lines[i] = p.indent .. desired .. " " .. p.content
        n_changed = n_changed + 1
      end
      counter = counter + 1
    end
  end
  if n_changed > 0 then
    obuf.set_lines(bufnr, s - 1, e, lines)
  end
  return n_changed
end

-- Sort items at the cursor's indent level. Sub-items move with their parent.
-- `comparator` is "alpha" (case-insensitive) | "numeric" | function(a, b).
function M.sort(bufnr, cursor_line, comparator)
  local s, e, indent = M.block_at(bufnr, cursor_line)
  if not s then
    return 0
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)

  -- Group: each group is a top-level item plus its trailing sub-items.
  local groups = {}
  local cur
  for _, ln in ipairs(lines) do
    local p = M.parse_item(ln)
    if p and #p.indent == indent then
      cur = { lines = { ln }, key = p.content:lower() }
      groups[#groups + 1] = cur
    elseif cur then
      cur.lines[#cur.lines + 1] = ln
    end
  end
  if #groups < 2 then
    return 0
  end

  local cmp
  if type(comparator) == "function" then
    cmp = function(a, b)
      return comparator(a.key, b.key)
    end
  elseif comparator == "numeric" then
    cmp = function(a, b)
      local na, nb = tonumber(a.key), tonumber(b.key)
      if na and nb then
        return na < nb
      end
      return a.key < b.key
    end
  else -- alpha (default)
    cmp = function(a, b)
      return a.key < b.key
    end
  end
  table.sort(groups, cmp)

  local new_lines = {}
  for _, g in ipairs(groups) do
    for _, ln in ipairs(g.lines) do
      new_lines[#new_lines + 1] = ln
    end
  end
  obuf.set_lines(bufnr, s - 1, e, new_lines)
  return #groups
end

-- Width of the bullet + trailing space, used to compute the indent
-- column where a sub-item starts beneath a parent.  `- ` / `+ ` / `* `
-- are width 2; `1. ` is width 3; `10. ` is width 4, etc.
local function prefix_width(item)
  -- `bullet` is "-"/"+"/"*" for unordered (length 1), or "1."/"2)" etc.
  -- for ordered (length = digits + 1 sep).
  return #item.bullet + 1
end

-- Walk upward from `line` looking for the previous list-item line that
-- the cursor's item belongs to (same or shallower indent).  Returns the
-- matched item's parse result + its line number, or nil if there isn't
-- one (cursor is the first item, or no list above).
local function previous_sibling(bufnr, line)
  local cur_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local cur = M.parse_item(cur_text)
  if not cur then
    return nil
  end
  for j = line - 1, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    local item = M.parse_item(text)
    if item and #item.indent <= #cur.indent then
      return item, j
    end
    -- A heading or a blank line ends the list scope.
    if text:match("^%*+%s") or text == "" then
      return nil
    end
  end
  return nil
end

-- Demote: indent the list item at `line` to become a sub-item of the
-- previous sibling.  Indent rule probed against Emacs 30.2:
--   new_indent = previous_sibling.indent + width(previous_sibling.bullet)
-- No-op if there's no previous sibling (Emacs raises "Cannot move item"
-- in that case).  Returns true on a change, false otherwise.
function M.demote(bufnr, line)
  local cur_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local cur = M.parse_item(cur_text)
  if not cur then
    return false
  end
  local prev = previous_sibling(bufnr, line)
  if not prev then
    return false
  end
  local new_indent = string.rep(" ", #prev.indent + prefix_width(prev))
  local body = cur_text:sub(#cur.indent + 1)
  local new_line = new_indent .. body
  if new_line == cur_text then
    return false
  end
  obuf.set_lines(bufnr, line - 1, line, { new_line })
  return true
end

-- Promote: un-indent the list item at `line` to the nearest ancestor's
-- indent (becomes a sibling of the ancestor).  Falls back to removing
-- two leading spaces if no strict ancestor is in scope.  Returns true
-- on a change, false if already at indent 0.
function M.promote(bufnr, line)
  local cur_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local cur = M.parse_item(cur_text)
  if not cur or #cur.indent == 0 then
    return false
  end
  for j = line - 1, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    local item = M.parse_item(text)
    if item and #item.indent < #cur.indent then
      local body = cur_text:sub(#cur.indent + 1)
      local new_line = item.indent .. body
      if new_line == cur_text then
        return false
      end
      obuf.set_lines(bufnr, line - 1, line, { new_line })
      return true
    end
    if text:match("^%*+%s") or text == "" then
      break
    end
  end
  if #cur.indent >= 2 then
    local body = cur_text:sub(#cur.indent + 1)
    obuf.set_lines(bufnr, line - 1, line, { cur.indent:sub(3) .. body })
    return true
  end
  return false
end

M._previous_sibling = previous_sibling
M._prefix_width = prefix_width

M.commands = {
  ["list repair"] = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local n = M.repair(bufnr, line)
      require("organ.notify").notify(
        n > 0 and vim.log.levels.INFO or vim.log.levels.WARN,
        ("re-sequenced %d item(s)"):format(n)
      )
    end,
    desc = "Re-sequence ordered-list numbering (1., 2., 3., ...) starting at the cursor's list",
  },
  ["list sort"] = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local cmp = cmd and cmd.args ~= "" and cmd.args or "alpha"
      local n = M.sort(bufnr, line, cmp)
      require("organ.notify").notify(
        n > 0 and vim.log.levels.INFO or vim.log.levels.WARN,
        ("sorted %d item(s) (%s)"):format(n, cmp)
      )
    end,
    nargs = "?",
    desc = "Sort the list at cursor by `alpha` (default), `numeric`, or `length`",
  },
  ["list demote"] = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      if not M.demote(bufnr, line) then
        require("organ.notify").warn("cannot demote: not on a list item or no previous sibling")
      end
    end,
    desc = "Indent the list item under the previous sibling (Emacs Tab-on-empty-bullet)",
  },
  ["list promote"] = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      if not M.promote(bufnr, line) then
        require("organ.notify").warn("cannot promote: not on a list item or already at indent 0")
      end
    end,
    desc = "Un-indent the list item to its ancestor's level",
  },
}

return M
