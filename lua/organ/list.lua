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
}

return M
