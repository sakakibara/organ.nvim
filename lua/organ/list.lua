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
  local indent, bullet, content = line:match("^(%s*)([%-%+])%s+(.*)$")
  if not bullet then
    -- A `*` bullet requires leading whitespace; unindented `*` is a
    -- headline.
    indent, bullet, content = line:match("^(%s+)(%*)%s+(.*)$")
  end
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
        -- A width change (`10.` -> `1.`) moves the text column, so the
        -- item's descendant lines shift with it to stay aligned under
        -- the new prefix (Emacs org-list-struct-fix-ind).
        local dw = #desired - #p.bullet
        if dw ~= 0 then
          for j = i + 1, #lines do
            local ws = lines[j]:match("^(%s*)")
            if #ws <= indent then
              break
            end
            lines[j] = string.rep(" ", math.max(0, #ws + dw)) .. lines[j]:sub(#ws + 1)
            n_changed = n_changed + 1
          end
        end
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

-- Last line of the item's subtree beyond the item line itself:
-- following lines more indented than the item (child items and
-- continuation text).  A blank line, a headline, or a line at the
-- item's indent or shallower ends it.
local function item_subtree_end(bufnr, line, cur_indent)
  local last = line
  local total = vim.api.nvim_buf_line_count(bufnr)
  for j = line + 1, total do
    local text = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    if text:match("^%s*$") or text:match("^%*+%s") then
      break
    end
    local ws = text:match("^(%s*)")
    if #ws <= cur_indent then
      break
    end
    last = j
  end
  return last
end

-- Remaining-item anchors at the item's current indent, outside its
-- subtree: the nearest item line above and the first below.  Captured
-- BEFORE an indent shift so the level the item leaves can be
-- renumbered afterwards.  Both are needed: a promote out of the middle
-- of a sub-list splits it in two, and each half renumbers on its own
-- (the lower half becomes a sub-list of the promoted item).
local function level_anchors(bufnr, line, cur)
  local s, e = M.block_at(bufnr, line)
  if not s then
    return nil, nil
  end
  local last = item_subtree_end(bufnr, line, #cur.indent)
  local above, below
  for j = s, line - 1 do
    local text = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    local item = M.parse_item(text)
    if item and #item.indent == #cur.indent then
      above = j
    end
  end
  for j = last + 1, e do
    local text = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    local item = M.parse_item(text)
    if item and #item.indent == #cur.indent then
      below = j
      break
    end
  end
  return above, below
end

-- Renumber the levels an indent op touched: the level the item joined
-- (recentered on its own line) and the level it left (via the anchors
-- captured before the shift).  Emacs runs the equivalent for every
-- list a structure edit touches, restarting each at 1 unless a `[@N]`
-- counter overrides.  repair() is a no-op on unordered levels.
local function renumber_after_shift(bufnr, line, above, below)
  M.repair(bufnr, line)
  if above then
    M.repair(bufnr, above)
  end
  if below then
    M.repair(bufnr, below)
  end
end

-- Re-indent the item at `line` by `delta` columns; with `tree`, its
-- child lines shift by the same amount (Emacs org-indent-item-tree).
local function shift_item(bufnr, line, cur, delta, tree)
  if delta == 0 then
    return false
  end
  local last = tree and item_subtree_end(bufnr, line, #cur.indent) or line
  local lines = vim.api.nvim_buf_get_lines(bufnr, line - 1, last, false)
  for i, text in ipairs(lines) do
    local ws = text:match("^(%s*)")
    lines[i] = string.rep(" ", math.max(0, #ws + delta)) .. text:sub(#ws + 1)
  end
  obuf.set_lines(bufnr, line - 1, last, lines)
  return true
end

-- Indent delta that nests the item at `line` under its previous
-- sibling (Emacs 30.2 rule: new_indent = sibling.indent +
-- width(its_bullet_prefix)).  nil when there's no previous sibling.
local function demote_delta(bufnr, line, cur)
  local prev = previous_sibling(bufnr, line)
  if not prev then
    return nil
  end
  return #prev.indent + prefix_width(prev) - #cur.indent
end

-- Indent delta that lifts the item at `line` to the nearest ancestor's
-- indent; falls back to -2 when no strict ancestor is in scope.  nil
-- when already at indent 0.
local function promote_delta(bufnr, line, cur)
  if #cur.indent == 0 then
    return nil
  end
  for j = line - 1, 1, -1 do
    local text = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    local item = M.parse_item(text)
    if item and #item.indent < #cur.indent then
      return #item.indent - #cur.indent
    end
    if text:match("^%*+%s") or text == "" then
      break
    end
  end
  if #cur.indent >= 2 then
    return -2
  end
  return nil
end

-- Demote: indent the list item at `line` to become a sub-item of the
-- previous sibling.  No-op if there's no previous sibling (Emacs raises
-- "Cannot move item" in that case).  `opts.tree` carries the item's
-- children along.  Returns true on a change, false otherwise.
function M.demote(bufnr, line, opts)
  local cur_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local cur = M.parse_item(cur_text)
  if not cur then
    return false
  end
  local delta = demote_delta(bufnr, line, cur)
  if not delta then
    return false
  end
  local above, below = level_anchors(bufnr, line, cur)
  if not shift_item(bufnr, line, cur, delta, opts and opts.tree) then
    return false
  end
  renumber_after_shift(bufnr, line, above, below)
  return true
end

-- Promote: un-indent the list item at `line` to the nearest ancestor's
-- indent (becomes a sibling of the ancestor).  `opts.tree` carries the
-- item's children along.  Returns true on a change, false if already
-- at indent 0.
function M.promote(bufnr, line, opts)
  local cur_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local cur = M.parse_item(cur_text)
  if not cur then
    return false
  end
  local delta = promote_delta(bufnr, line, cur)
  if not delta then
    return false
  end
  local above, below = level_anchors(bufnr, line, cur)
  if not shift_item(bufnr, line, cur, delta, opts and opts.tree) then
    return false
  end
  renumber_after_shift(bufnr, line, above, below)
  return true
end

-- Swap the item at `line` (with its children) with the sibling above/
-- below at the same indent (Emacs org-metaup / org-metadown on an
-- item).  Ordered bullets stay positional -- the two items exchange
-- their bullet numbers (probed against Emacs 30.2: metaup on `2. two`
-- yields `1. two / 2. one`).  Returns the item's new first line, or
-- false when there's no same-indent sibling to swap with (Emacs:
-- "Cannot move this item further up/down").
function M.move(bufnr, line, dir)
  local cur_text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  local cur = M.parse_item(cur_text)
  if not cur then
    return false
  end
  local cur_end = item_subtree_end(bufnr, line, #cur.indent)
  local other_start, other_end, other
  if dir == "up" then
    for j = line - 1, 1, -1 do
      local text = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
      if text:match("^%s*$") or text:match("^%*+%s") then
        break
      end
      local item = M.parse_item(text)
      if item then
        if #item.indent == #cur.indent then
          other_start, other_end, other = j, line - 1, item
          break
        elseif #item.indent < #cur.indent then
          break
        end
      elseif #text:match("^(%s*)") <= #cur.indent then
        break
      end
    end
  else
    local nxt = cur_end + 1
    local text = vim.api.nvim_buf_get_lines(bufnr, nxt - 1, nxt, false)[1] or ""
    local item = M.parse_item(text)
    if item and #item.indent == #cur.indent then
      other_start, other_end, other = nxt, item_subtree_end(bufnr, nxt, #item.indent), item
    end
  end
  if not other_start then
    return false
  end
  local cur_block = vim.api.nvim_buf_get_lines(bufnr, line - 1, cur_end, false)
  local other_block = vim.api.nvim_buf_get_lines(bufnr, other_start - 1, other_end, false)
  if cur.counter and other.counter then
    cur_block[1] = cur.indent .. other.bullet .. " " .. cur.content
    other_block[1] = other.indent .. cur.bullet .. " " .. other.content
  end
  local combined, new_line
  if dir == "up" then
    new_line = other_start
    combined = vim.list_extend(cur_block, other_block)
  else
    new_line = line + #other_block
    combined = vim.list_extend(other_block, cur_block)
  end
  obuf.set_lines(bufnr, math.min(line, other_start) - 1, math.max(cur_end, other_end), combined)
  return new_line
end

-- Shift every line in [s, e] as a block, one indent level in `dir`
-- ("promote" or "demote").  The region must start on a list item
-- (Emacs region org-indent-item: "Region not starting at an item");
-- the delta comes from that first item.  Blank lines stay empty.
-- Returns true on a change, false otherwise.
function M.shift_region(bufnr, s, e, dir)
  local first = vim.api.nvim_buf_get_lines(bufnr, s - 1, s, false)[1] or ""
  local cur = M.parse_item(first)
  if not cur then
    return false
  end
  local delta = (dir == "promote") and promote_delta(bufnr, s, cur) or demote_delta(bufnr, s, cur)
  if not delta or delta == 0 then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  for i, text in ipairs(lines) do
    if not text:match("^%s*$") then
      local ws = text:match("^(%s*)")
      lines[i] = string.rep(" ", math.max(0, #ws + delta)) .. text:sub(#ws + 1)
    end
  end
  obuf.set_lines(bufnr, s - 1, e, lines)
  return true
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
