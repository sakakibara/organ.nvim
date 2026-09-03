-- List operations: promote / demote, repair, sort, move, counter
-- handling for `[@N]` start markers.
--
-- Structure ops use org's list struct model: an item's parent is the
-- closest item above with smaller indent, siblings share a parent
-- (indent equality is not required), and every op ends by rewriting
-- the whole structure -- indentation from each parent's bullet width,
-- one bullet style per list (the first item's), numbering restarting
-- at 1 unless an `[@N]` counter overrides.  Line-based -- no
-- tree-sitter dependency -- so editing buffers in progress is safe.

local M = {}

local obuf = require("organ.buf")
-- Parse one line into { indent, bullet, counter, content } or nil.
--   indent  = leading whitespace string
--   bullet  = "-" / "+" / "*" (unordered) OR "1." / "2)" (ordered)
--   counter = numeric value of an ordered bullet, or nil for unordered
--   content = the body after the bullet
function M.parse_item(line)
  -- A bare bullet at end of line is an item too (Emacs `org-item-re`).
  local indent, bullet, content = line:match("^(%s*)([%-%+])%s+(.*)$")
  if not bullet then
    indent, bullet = line:match("^(%s*)([%-%+])$")
    content = ""
  end
  if not bullet then
    -- A `*` bullet requires leading whitespace; unindented `*` is a
    -- headline.
    indent, bullet, content = line:match("^(%s+)(%*)%s+(.*)$")
  end
  if not bullet then
    indent, bullet = line:match("^(%s+)(%*)$")
    content = ""
  end
  if bullet then
    return { indent = indent, bullet = bullet, content = content }
  end
  local i, num, sep, c = line:match("^(%s*)(%d+)([.)])%s+(.*)$")
  if not num then
    i, num, sep = line:match("^(%s*)(%d+)([.)])$")
    c = ""
  end
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
-- indent level — items at deeper indents and non-item lines indented
-- past the level (item body text) are accepted as continuations; a
-- non-item line at the level or shallower ends the block.  A single
-- blank line keeps the list going (a loose list); two consecutive
-- blanks end it, per org.
function M.block_at(bufnr, cursor_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local center = M.parse_item(lines[cursor_line] or "")
  if not center then
    return nil
  end
  local center_indent = #center.indent

  local s, e = cursor_line, cursor_line
  for i = cursor_line - 1, 1, -1 do
    local ln = lines[i] or ""
    local p = M.parse_item(ln)
    if p and #p.indent >= center_indent then
      s = i
    elseif ln:match("^%s*$") then
      if i == 1 or (lines[i - 1] or ""):match("^%s*$") then
        break
      end
    elseif #ln:match("^(%s*)") <= center_indent then
      break
    end
    -- deeper non-item line: an item's body text; keep scanning (s stays
    -- on the last item — a body line always follows its item)
  end
  for i = cursor_line + 1, #lines do
    local ln = lines[i] or ""
    local p = M.parse_item(ln)
    if p and #p.indent >= center_indent then
      e = i
    elseif ln:match("^%s*$") then
      if (lines[i + 1] or ""):match("^%s*$") then
        break
      end
    elseif #ln:match("^(%s*)") <= center_indent then
      break
    else
      e = i
    end
  end
  return s, e, center_indent
end

-- Parse the whole list structure around `line` (which must be an item
-- line): scope bounds, item array (row / indent / bullet / sep /
-- counter / content, in row order), and the buffer lines.  Scope walks
-- across items at any indent, item body text (non-item lines indented
-- past the structure's first item), and single blanks; a headline,
-- flush-left text, body text at or left of the first item's indent, or
-- two consecutive blanks end it.
local function parse_struct(bufnr, line)
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not M.parse_item(buf_lines[line] or "") then
    return nil
  end
  -- Up-walk with a descending ceiling: a non-item line at `ws` closes
  -- every item region at ws or deeper, so items above it belong to the
  -- cursor's structure only when shallower (a common ancestor); ones at
  -- or past the ceiling are skipped without extending the scope.
  local s = line
  local limit = math.huge
  for i = line - 1, 1, -1 do
    local ln = buf_lines[i] or ""
    local p = M.parse_item(ln)
    if p then
      if #p.indent < limit then
        s = i
      end
    elseif ln:match("^%s*$") then
      if i == 1 or (buf_lines[i - 1] or ""):match("^%s*$") then
        break
      end
    elseif ln:match("^%*+%s") or #ln:match("^(%s*)") == 0 then
      break
    else
      limit = math.min(limit, #ln:match("^(%s*)"))
    end
  end
  local top_ind = #M.parse_item(buf_lines[s]).indent
  local items = {}
  local e = s
  for i = s, #buf_lines do
    local ln = buf_lines[i] or ""
    local p = M.parse_item(ln)
    if p then
      items[#items + 1] = {
        row = i,
        ind = #p.indent,
        bullet = p.bullet,
        sep = p.sep,
        counter = p.counter,
        content = p.content,
      }
      e = i
    elseif ln:match("^%s*$") then
      if (buf_lines[i + 1] or ""):match("^%s*$") then
        break
      end
    elseif ln:match("^%*+%s") or #ln:match("^(%s*)") <= top_ind then
      break
    else
      e = i
    end
  end
  return { s = s, e = e, top_ind = top_ind, items = items, buf_lines = buf_lines }
end

-- Build the parent tree and list grouping for a struct.  Walks the
-- scope rows with a stack of open item regions: an item pops every
-- open item at its indent or deeper and attaches to the remaining top;
-- a non-blank non-item line CLOSES every open item at its indent or
-- deeper (org: an item ends before a line indented at or left of its
-- bullet), so a paragraph between two sibling runs severs them into
-- separate lists -- same parent, but numbering and bullet style run
-- per list, and demoting the first item of the later run has no
-- sibling to nest under.  `group[i]` identifies the list an item
-- belongs to.  `use_target` reads the op-adjusted indents (`tind`) so
-- the post-op tree can be computed before the buffer is rewritten.
local function analyze(st, use_target)
  local items = st.items
  local function ind_of(i)
    return use_target and (items[i].tind or items[i].ind) or items[i].ind
  end
  local by_row = {}
  for i, it in ipairs(items) do
    by_row[it.row] = i
  end
  local parent, group = {}, {}
  local stack = {}
  local last_child = {} -- parent index (0 = top) -> last child index
  local gid = 0
  local pending -- min ws of non-item lines since the last item row
  for row = st.s, st.e do
    local i = by_row[row]
    if i then
      while #stack > 0 and ind_of(stack[#stack]) >= ind_of(i) do
        stack[#stack] = nil
      end
      parent[i] = stack[#stack]
      local pk = parent[i] or 0
      local prev = last_child[pk]
      local severed = pending ~= nil and pending <= ind_of(i)
      if prev and not severed then
        group[i] = group[prev]
      else
        gid = gid + 1
        group[i] = gid
      end
      last_child[pk] = i
      stack[#stack + 1] = i
      pending = nil
    else
      local ln = st.buf_lines[row] or ""
      if not ln:match("^%s*$") then
        local ws = #ln:match("^(%s*)")
        pending = math.min(pending or math.huge, ws)
        while #stack > 0 and ind_of(stack[#stack]) >= ws do
          stack[#stack] = nil
        end
      end
    end
  end
  return parent, group
end

-- Closest earlier item in i's list (same group), or nil (i is the
-- first item of its list).
local function prev_in_group(group, i)
  for j = i - 1, 1, -1 do
    if group[j] == group[i] then
      return j
    end
  end
  return nil
end

-- Rewrite the structure from its parent tree (Emacs
-- org-list-write-struct): item indent = parent's indent + parent's new
-- bullet width + 1 (top level anchors at `st.top_ind`); one bullet
-- style per list, taken from its first item; ordered lists renumber
-- from 1, an `[@N]` counter on any member overriding the count there.
-- Item body lines shift with their owning item.  Returns the number of
-- changed lines.
local function write_struct(bufnr, st, parent, group, opts)
  local items = st.items
  local new_ind, new_bul = {}, {}
  local first_of, counters = {}, {}
  for i, it in ipairs(items) do
    local gk = group[i]
    local first = first_of[gk]
    if not first then
      first_of[gk] = i
      first = i
    end
    local fit = items[first]
    new_ind[i] = parent[i] and (new_ind[parent[i]] + #new_bul[parent[i]] + 1) or st.top_ind
    if fit.counter then
      local cookie = it.content:match("^%[@(%d+)%]")
      local n = cookie and tonumber(cookie)
      if not n and i == first and opts and opts.preserve_start then
        n = tonumber(it.bullet:match("^(%d+)") or "")
      end
      n = n or ((counters[gk] or 0) + 1)
      counters[gk] = n
      new_bul[i] = tostring(n) .. fit.sep
    else
      new_bul[i] = fit.bullet
    end
  end

  local by_row = {}
  for i, it in ipairs(items) do
    by_row[it.row] = i
  end
  local out = {}
  local changed = 0
  local cur
  for row = st.s, st.e do
    local old = st.buf_lines[row] or ""
    local new_line = old
    local i = by_row[row]
    if i then
      cur = i
      new_line = string.rep(" ", new_ind[i]) .. new_bul[i] .. " " .. items[i].content
    elseif not old:match("^%s*$") and cur then
      -- Body line: owned by the closest preceding item whose (original)
      -- indent is smaller than the line's — shift by that item's delta.
      local ws = #old:match("^(%s*)")
      local k = cur
      while k >= 1 and items[k].ind >= ws do
        k = k - 1
      end
      if k >= 1 then
        local delta = new_ind[k] - items[k].ind
        if delta ~= 0 then
          new_line = string.rep(" ", math.max(0, ws + delta)) .. old:sub(ws + 1)
        end
      end
    end
    if new_line ~= old then
      changed = changed + 1
    end
    out[#out + 1] = new_line
  end
  if changed > 0 then
    obuf.set_lines(bufnr, st.s - 1, st.e, out)
  end
  return changed
end

-- Promote / demote core.  Adjusts the item's (and, with `tree`, its
-- descendants') target indent in the struct, recomputes the parent
-- tree, and rewrites the whole structure.  On the structure's first
-- item the entire list shifts one column instead (Emacs).  Returns
-- true on change, or false plus a reason.
local function indent_op(bufnr, line, dir, tree)
  local st = parse_struct(bufnr, line)
  if not st then
    return false
  end
  local items = st.items
  local idx
  for i, it in ipairs(items) do
    if it.row == line then
      idx = i
      break
    end
  end
  if not idx then
    return false
  end
  local parent, group = analyze(st)

  if idx == 1 then
    if not tree then
      return false, "at the first item: use the subtree variant to move the whole list"
    end
    if dir == "promote" and st.top_ind == 0 then
      return false, "cannot outdent: list is already flush left"
    end
    st.top_ind = st.top_ind + (dir == "demote" and 1 or -1)
    return write_struct(bufnr, st, parent, group) > 0
  end

  local target
  if dir == "demote" then
    local sib = prev_in_group(group, idx)
    if not sib then
      return false, "cannot indent the first item of a sub-list"
    end
    target = items[sib].ind + #items[sib].bullet + 1
  else
    local par = parent[idx]
    if not par then
      return false, "cannot outdent: item has no parent"
    end
    if not tree then
      for i = idx + 1, #items do
        if parent[i] == idx then
          return false, "cannot outdent an item without its children"
        end
      end
    end
    target = items[par].ind
  end

  local delta = target - items[idx].ind
  items[idx].tind = target
  if tree then
    for i = idx + 1, #items do
      local k = parent[i]
      while k and k ~= idx do
        k = parent[k]
      end
      if k == idx then
        items[i].tind = items[i].ind + delta
      end
    end
  end
  local parent2, group2 = analyze(st, true)
  return write_struct(bufnr, st, parent2, group2) > 0
end

-- Repair: normalize the whole structure at the cursor (Emacs
-- org-list-repair) -- indentation, bullet styles, numbering.  Returns
-- the number of changed lines, plus the structure's line range so a
-- caller sweeping a buffer can skip past it.
--
-- `opts.preserve_start` numbers each ordered run from the number its
-- first item already carries instead of restarting at 1, so a sweep over
-- a whole buffer cannot rewrite prose that merely opens with a number.
function M.repair(bufnr, cursor_line, opts)
  local st = parse_struct(bufnr, cursor_line)
  if not st then
    return 0
  end
  local parent, group = analyze(st)
  return write_struct(bufnr, st, parent, group, opts), st.s, st.e
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
  elseif comparator == "length" then
    cmp = function(a, b)
      local la, lb = vim.fn.strdisplaywidth(a.key), vim.fn.strdisplaywidth(b.key)
      if la ~= lb then
        return la < lb
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

-- Last line of the item's subtree beyond the item line itself:
-- following lines more indented than the item (child items and
-- continuation text).  A headline or a line at the item's indent or
-- shallower ends it; a single blank keeps a loose subtree going, two
-- consecutive blanks end it.
local function item_subtree_end(bufnr, line, cur_indent)
  local last = line
  local total = vim.api.nvim_buf_line_count(bufnr)
  for j = line + 1, total do
    local text = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
    if text:match("^%s*$") then
      local below = vim.api.nvim_buf_get_lines(bufnr, j, j + 1, false)[1] or ""
      if below:match("^%s*$") then
        break
      end
    elseif text:match("^%*+%s") then
      break
    else
      local ws = text:match("^(%s*)")
      if #ws <= cur_indent then
        break
      end
      last = j
    end
  end
  return last
end

-- Demote: nest the item at `line` under its previous sibling.
-- `opts.tree` carries its children along (org-shiftmetaright);
-- without it the children stay and re-attach by depth (org-metaright).
-- On the structure's first item the whole list indents one column.
-- Returns true on a change, or false plus a reason (the first item of
-- a sub-list cannot be demoted -- it has no sibling to nest under).
function M.demote(bufnr, line, opts)
  return indent_op(bufnr, line, "demote", opts and opts.tree)
end

-- Promote: lift the item at `line` to its parent's level, becoming
-- the parent's next sibling.  `opts.tree` carries its children along
-- (org-shiftmetaleft); without it an item that has children refuses
-- (org-metaleft: "Cannot outdent an item without its children").  On
-- the structure's first item the whole list outdents one column.
-- Returns true on a change, or false plus a reason.
function M.promote(bufnr, line, opts)
  return indent_op(bufnr, line, "promote", opts and opts.tree)
end

-- Swap the item at `line` (with its children) with the sibling above/
-- below at the same indent (Emacs org-metaup / org-metadown on an
-- item).  Ordered bullets stay positional -- the two items exchange
-- their bullet numbers (Emacs: metaup on `2. two`
-- yields `1. two / 2. one`).  Returns the item's new first line, or
-- false when there's no same-indent sibling to swap with (Emacs:
-- "Cannot move this item further up/down").
function M.move(bufnr, line, dir)
  local function get(j)
    return vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1] or ""
  end
  local cur = M.parse_item(get(line))
  if not cur then
    return false
  end
  local cur_end = item_subtree_end(bufnr, line, #cur.indent)
  local other_start, other_end, other
  if dir == "up" then
    for j = line - 1, 1, -1 do
      local text = get(j)
      if text:match("^%*+%s") then
        break
      elseif text:match("^%s*$") then
        if j == 1 or get(j - 1):match("^%s*$") then
          break
        end
      else
        local item = M.parse_item(text)
        if item then
          if #item.indent == #cur.indent then
            other_start, other = j, item
            other_end = item_subtree_end(bufnr, j, #item.indent)
            break
          elseif #item.indent < #cur.indent then
            break
          end
        elseif #text:match("^(%s*)") <= #cur.indent then
          break
        end
      end
    end
  else
    local total = vim.api.nvim_buf_line_count(bufnr)
    local nxt = cur_end + 1
    if nxt <= total and get(nxt):match("^%s*$") then
      nxt = nxt + 1
    end
    local item = nxt <= total and M.parse_item(get(nxt)) or nil
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
  -- Blank lines between the two items stay where they are (Emacs
  -- org-list-swap-items).
  local between, combined, new_line
  if dir == "up" then
    between = vim.api.nvim_buf_get_lines(bufnr, other_end, line - 1, false)
    new_line = other_start
    combined = vim.list_extend(vim.list_extend(cur_block, between), other_block)
  else
    between = vim.api.nvim_buf_get_lines(bufnr, cur_end, other_start - 1, false)
    new_line = line + #other_block + #between
    combined = vim.list_extend(vim.list_extend(other_block, between), cur_block)
  end
  obuf.set_lines(bufnr, math.min(line, other_start) - 1, math.max(cur_end, other_end), combined)
  return new_line
end

-- Shift every line in [s, e] as a block, one indent level in `dir`
-- ("promote" or "demote").  The region must start on a list item
-- (Emacs region org-indent-item: "Region not starting at an item");
-- the delta comes from that first item's struct position.  Blank
-- lines stay empty.  Returns true on a change, false otherwise.
function M.shift_region(bufnr, s, e, dir)
  local st = parse_struct(bufnr, s)
  if not st then
    return false
  end
  local idx
  for i, it in ipairs(st.items) do
    if it.row == s then
      idx = i
      break
    end
  end
  if not idx then
    return false
  end
  local parent, group = analyze(st)
  local delta
  if dir == "demote" then
    local sib = prev_in_group(group, idx)
    if not sib then
      return false
    end
    delta = st.items[sib].ind + #st.items[sib].bullet + 1 - st.items[idx].ind
  else
    local par = parent[idx]
    if par then
      delta = st.items[par].ind - st.items[idx].ind
    elseif st.items[idx].ind >= 2 then
      delta = -2
    else
      return false
    end
  end
  if delta == 0 then
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
        vim.log.levels.INFO,
        n > 0 and ("normalized %d line(s)"):format(n) or "list already canonical"
      )
    end,
    desc = "Normalize the list at cursor: indentation, bullet styles, numbering",
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
      local ok, why = M.demote(bufnr, line)
      if not ok then
        require("organ.notify").warn(why or "cannot demote: not on a list item")
      end
    end,
    desc = "Indent the list item under the previous sibling (Emacs Tab-on-empty-bullet)",
  },
  ["list promote"] = {
    fn = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      local ok, why = M.promote(bufnr, line)
      if not ok then
        require("organ.notify").warn(why or "cannot promote: not on a list item")
      end
    end,
    desc = "Un-indent the list item to its ancestor's level",
  },
}

return M
