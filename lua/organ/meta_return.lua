-- Context-aware new-element insertion (Emacs `org-meta-return`).
--
--   * On a headline OR a body
--     line inside a subtree   → insert a new same-level headline at
--                               the end of the current subtree (matches
--                               Emacs `org-insert-heading-respect-content`).
--   * On a list item          → insert a new sibling item with the same
--                               bullet style (auto-renumbers a numeric
--                               list following the new item).
--   * Inside a table          → insert a new row below.
--   * Before the first heading
--     (no enclosing subtree)  → behave like Vim's `o` (open below).
--
-- Cursor is moved to the new line, in insert mode if `enter_insert` is
-- true (default).

local M = {}

local obuf = require("organ.buf")
local function get_line(bufnr, lnum)
  return vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
end

local function set_lines(bufnr, lnum_after, new_lines)
  obuf.set_lines(bufnr, lnum_after, lnum_after, new_lines)
end

local function move_to(line, col)
  vim.api.nvim_win_set_cursor(0, { line, col })
end

-- Headline detector: `*+ ` at column 0.
local function headline_level(text)
  local stars = text:match("^(%*+)%s")
  return stars and #stars or nil
end

-- Find the headline owning a given line — walks upward.
local function enclosing_headline(bufnr, line)
  for i = line, 1, -1 do
    local lvl = headline_level(get_line(bufnr, i))
    if lvl then
      return i, lvl
    end
  end
  return nil
end

-- A list item line: returns indent + bullet representation, OR nil if
-- not on a list item.  Mirrors organ.checkbox.parse_item_line but only
-- needs to identify the bullet style for replication.
local function item_bullet(text)
  -- `- ` or `+ `
  local m = text:match("^(%s*)([-+])%s")
  if m then
    return text:match("^(%s*)"), text:match("^%s*(%S)"), "literal"
  end
  -- `* ` at indent > 0
  local indent = text:match("^(%s+)") or ""
  if indent ~= "" and text:match("^%s+%*%s") then
    return indent, "*", "literal"
  end
  -- `N. ` or `N) `
  local n, sep = text:match("^(%s*)(%d+)([%.%)])%s")
  if n then
    return text:match("^(%s*)"), nil, "numeric", text:match("^%s*(%d+)([%.%)])"):sub(-1)
  end
  return nil
end

-- Find the bullet style of `line` if it's a list item.  Returns
--   { indent = "  ", style = "literal"|"numeric", char = "-"|"+"|"*", sep = "."|")", n = N }
-- or nil.
local function parse_bullet(text)
  local lit_indent, lit_char = text:match("^(%s*)([-+])%s")
  if lit_indent then
    return { indent = lit_indent, style = "literal", char = lit_char }
  end
  local star_indent = text:match("^(%s+)%*%s")
  if star_indent then
    return { indent = star_indent, style = "literal", char = "*" }
  end
  local num_indent, num, sep = text:match("^(%s*)(%d+)([%.%)])%s")
  if num_indent then
    return { indent = num_indent, style = "numeric", n = tonumber(num), sep = sep }
  end
  return nil
end

-- Detect whether `text` is a table row (`|`-prefixed).
local function is_table_row(text)
  return text:match("^%s*|") ~= nil
end

-- Renumber a contiguous numeric list starting at `start_line`.  Walks
-- forward while the indent matches `indent` and the bullet stays
-- numeric, rewriting `N. `/`N) ` to a continuous sequence beginning at
-- `start_n`.
local function renumber(bufnr, start_line, indent, sep, start_n)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local n = start_n
  for ln = start_line, total do
    local txt = get_line(bufnr, ln)
    local i, num, s = txt:match("^(%s*)(%d+)([%.%)])%s")
    if not i or i ~= indent or s ~= sep then
      break
    end
    if tonumber(num) ~= n then
      local new = txt:gsub("^(%s*)%d+([" .. sep .. "]%s)", "%1" .. n .. "%2", 1)
      obuf.set_lines(bufnr, ln - 1, ln, { new })
    end
    n = n + 1
  end
end

-- Public entry.
function M.dispatch(opts)
  opts = opts or {}
  local enter_insert = opts.enter_insert ~= false
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local cur_line = cur[1]
  local txt = get_line(bufnr, cur_line)

  -- 1. Headline → new sibling headline at the end of this subtree.
  local lvl = headline_level(txt)
  if lvl then
    -- Walk past every line still inside this subtree: non-headline
    -- lines AND deeper-level child headlines.  Stop on the first
    -- sibling-or-higher headline (sub_lvl <= lvl) or EOF.  Matches
    -- Emacs `org-end-of-subtree`.
    local total = vim.api.nvim_buf_line_count(bufnr)
    local end_line = cur_line
    for i = cur_line + 1, total do
      local sub_lvl = headline_level(get_line(bufnr, i))
      if sub_lvl and sub_lvl <= lvl then
        break
      end
      end_line = i
    end
    local stars = string.rep("*", lvl)
    set_lines(bufnr, end_line, { stars .. " " })
    -- Apply the buffer's empty-line policy around the freshly inserted
    -- heading so it inherits the blank-line style the user already
    -- writes (auto-detect each call, so paste-into-different-style
    -- buffers behave naturally).
    local spacing = require("organ.spacing")
    local pre = vim.api.nvim_buf_line_count(bufnr)
    local heading_row = end_line + 1
    spacing.normalize_around(bufnr, heading_row, spacing.resolve(bufnr))
    -- normalize_around may have inserted blanks above the heading;
    -- shift the cursor target by however many lines the buffer grew.
    heading_row = heading_row + (vim.api.nvim_buf_line_count(bufnr) - pre)
    move_to(heading_row, #stars + 1)
    if enter_insert then
      vim.cmd("startinsert!")
    end
    return
  end

  -- 2. List item → new sibling item.
  local bullet = parse_bullet(txt)
  if bullet then
    local prefix
    if bullet.style == "literal" then
      prefix = bullet.indent .. bullet.char .. " "
    else
      prefix = bullet.indent .. (bullet.n + 1) .. bullet.sep .. " "
    end
    set_lines(bufnr, cur_line, { prefix })
    if bullet.style == "numeric" then
      renumber(bufnr, cur_line + 1, bullet.indent, bullet.sep, bullet.n + 1)
    end
    move_to(cur_line + 1, #prefix)
    if enter_insert then
      vim.cmd("startinsert!")
    end
    return
  end

  -- 3. Table row → new row below (mirrors the column count).
  if is_table_row(txt) then
    -- Count the number of `|` separators; replicate as empty cells.
    local pipes = 0
    for _ in txt:gmatch("|") do
      pipes = pipes + 1
    end
    local n_cells = math.max(pipes - 1, 1)
    local new = "|" .. string.rep("  |", n_cells)
    set_lines(bufnr, cur_line, { new })
    move_to(cur_line + 1, 2)
    if enter_insert then
      vim.cmd("startinsert")
    end
    return
  end

  -- 4. Body line inside a subtree (not a list item or table row) → new
  -- sibling headline at the enclosing level, inserted after this
  -- subtree's content.  Mirrors Emacs `org-insert-heading-respect-
  -- content = t` (the common user config): from anywhere inside a
  -- subtree, M-RET produces a new heading at the same level appended
  -- below, never splitting the body line at point.
  local _hl_line, hl_lvl = enclosing_headline(bufnr, cur_line)
  if hl_lvl then
    local total = vim.api.nvim_buf_line_count(bufnr)
    local end_line = cur_line
    -- Walk past every line that's still inside this subtree.  A line
    -- counts as still-inside as long as it's NOT a headline OR is a
    -- deeper-level headline (i.e. a child of `hl_lvl`).  We stop on
    -- the first sibling-or-higher headline (level <= hl_lvl) or EOF.
    -- Matches Emacs `org-end-of-subtree`.
    for i = cur_line + 1, total do
      local lvl = headline_level(get_line(bufnr, i))
      if lvl and lvl <= hl_lvl then
        break
      end
      end_line = i
    end
    local stars = string.rep("*", hl_lvl)
    set_lines(bufnr, end_line, { stars .. " " })
    local spacing = require("organ.spacing")
    local pre = vim.api.nvim_buf_line_count(bufnr)
    local heading_row = end_line + 1
    spacing.normalize_around(bufnr, heading_row, spacing.resolve(bufnr))
    heading_row = heading_row + (vim.api.nvim_buf_line_count(bufnr) - pre)
    move_to(heading_row, #stars + 1)
    if enter_insert then
      vim.cmd("startinsert!")
    end
    return
  end

  -- 5. Fallback (before any heading, no list/table context) — open a fresh blank line below.
  set_lines(bufnr, cur_line, { "" })
  move_to(cur_line + 1, 0)
  if enter_insert then
    vim.cmd("startinsert!")
  end
end

M.commands = {
  meta_return = {
    fn = function()
      M.dispatch({ enter_insert = false })
    end,
    desc = "Insert a new element appropriate to the cursor context (heading / list item / row / link)",
  },
}

return M
