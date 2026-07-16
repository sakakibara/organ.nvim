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
--   * Buffer with no headings
--     anywhere                → create a level-1 heading (truly-empty
--                               buffer becomes `* `; preamble-only
--                               buffer gets `* ` appended at end with
--                               spacing-policy applied).
--   * Preamble of a buffer
--     that has headings       → behave like Vim's `o` (open below).
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

-- Find the bullet style of `line` if it's a list item.  Returns
--   { indent = "  ", style = "literal"|"numeric", char = "-"|"+"|"*",
--     sep = "."|")", n = N, desc = bool }
-- or nil.  `desc` marks a description item: an unordered bullet whose
-- text carries a ` :: ` separator (or ends with ` ::`).
local function parse_bullet(text)
  local lit_indent, lit_char, lit_rest = text:match("^(%s*)([-+])%s+(.*)$")
  if not lit_indent then
    lit_indent, lit_char, lit_rest = text:match("^(%s+)(%*)%s+(.*)$")
  end
  if lit_indent then
    local desc = lit_rest:find(" :: ", 1, true) ~= nil or lit_rest:match(" ::$") ~= nil
    return { indent = lit_indent, style = "literal", char = lit_char, desc = desc }
  end
  local num_indent, num, sep = text:match("^(%s*)(%d+)([%.%)])%s")
  if num_indent then
    return { indent = num_indent, style = "numeric", n = tonumber(num), sep = sep }
  end
  return nil
end

-- 0-based column of the first text character after the bullet, or nil.
local function item_text_col(text)
  local p = text:match("^%s*[-+*]%s+()") or text:match("^%s*%d+[%.%)]%s+()")
  return p and (p - 1) or nil
end

-- Detect whether `text` is a table row (`|`-prefixed).
local function is_table_row(text)
  return text:match("^%s*|") ~= nil
end

-- After inserting a new heading and normalizing its spacing, the next
-- adjacent heading may have lost its own before-blank to the new one
-- (in styles like `before=1,after=0` where the blank sits ABOVE each
-- heading, not below).  Walk forward past any blanks; if the very next
-- non-blank line is a heading, re-normalize it with the same policy so
-- it gets its blank-above restored.
local function normalize_following_heading(bufnr, after_row, policy)
  local total = vim.api.nvim_buf_line_count(bufnr)
  for j = after_row + 1, total do
    local l = vim.api.nvim_buf_get_lines(bufnr, j - 1, j, false)[1]
    if not l then
      return
    end
    if l:match("^%*+%s") then
      require("organ.spacing").normalize_around(bufnr, j, policy)
      return
    end
    if not l:match("^%s*$") then
      return
    end
  end
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

-- Public entry.  `opts.todo` makes the inserted element a TODO one
-- (Emacs M-S-RET, org-insert-todo-heading): headings get the first
-- active keyword of the reference entry's TODO sequence, list items
-- get an unchecked checkbox.
function M.dispatch(opts)
  opts = opts or {}
  local enter_insert = opts.enter_insert ~= false
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)
  local cur_line = cur[1]
  local txt = get_line(bufnr, cur_line)

  -- Keyword for a new TODO heading: head of the sequence containing
  -- the reference headline's current state (`headline_text` nil for
  -- "no reference entry" -> first sequence).  nil when opts.todo is
  -- off.
  local function todo_keyword(headline_text)
    if not opts.todo then
      return nil
    end
    local state = headline_text and headline_text:match("^%*+%s+(%S+)")
    return require("organ.todo").sequence_head(bufnr, state)
  end

  -- 1. Headline → new sibling headline at the end of this subtree.
  local lvl = headline_level(txt)
  if lvl then
    local kw = todo_keyword(txt)
    local heading_prefix = string.rep("*", lvl) .. " " .. (kw and (kw .. " ") or "")
    -- Optional Emacs point-splitting (`meta_return.split_headline`):
    -- with the cursor inside the title, break it there -- the tail
    -- becomes a new same-level headline right below, so body and
    -- children end up attached to the tail.  The split lands before
    -- the cursor character (the `i` convention).
    local cfg = require("organ.buf_config").read(nil, "meta_return") or {}
    local col = cur[2]
    local title_start = (txt:match("^%*+%s+()") or 1) - 1
    if cfg.split_headline and col > title_start and col < #txt then
      local head = txt:sub(1, col)
      local tail = heading_prefix .. txt:sub(col + 1)
      obuf.set_lines(bufnr, cur_line - 1, cur_line, { head, tail })
      move_to(cur_line + 1, math.max(#tail - 1, 0))
      if enter_insert then
        vim.cmd("startinsert!")
      end
      return
    end
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
    set_lines(bufnr, end_line, { heading_prefix })
    -- Apply the buffer's empty-line policy around the freshly inserted
    -- heading so it inherits the blank-line style the user already
    -- writes (auto-detect each call, so paste-into-different-style
    -- buffers behave naturally).
    local spacing = require("organ.spacing")
    local policy = spacing.resolve(bufnr)
    local heading_row = spacing.normalize_around(bufnr, end_line + 1, policy) or (end_line + 1)
    normalize_following_heading(bufnr, heading_row, policy)
    move_to(heading_row, #heading_prefix)
    if enter_insert then
      vim.cmd("startinsert!")
    end
    return
  end

  -- 2. List item → new sibling item.  A description item gets the
  -- ` :: ` skeleton with the cursor in the term slot (Emacs
  -- org-insert-item on a description list).  With opts.todo the
  -- sibling carries an unchecked checkbox, whatever the current
  -- item's state.
  local bullet = parse_bullet(txt)
  if bullet then
    local prefix
    if bullet.style == "literal" then
      prefix = bullet.indent .. bullet.char .. " "
    else
      prefix = bullet.indent .. (bullet.n + 1) .. bullet.sep .. " "
    end
    if opts.todo then
      prefix = prefix .. "[ ] "
    end
    -- Optional Emacs point-splitting (`meta_return.split_item`): with
    -- the cursor inside the item text, break it there.  The tail
    -- becomes a new sibling right below (children then follow the
    -- tail); a checkbox stays on the head; a description tail keeps
    -- the ` :: ` skeleton.  The split lands before the cursor
    -- character (the `i` convention).
    local cfg = require("organ.buf_config").read(nil, "meta_return") or {}
    local col = cur[2]
    local text_start = item_text_col(txt)
    if cfg.split_item and text_start and col > text_start and col < #txt then
      local head = txt:sub(1, col)
      local tail_text = txt:sub(col + 1)
      local tail = bullet.desc and (prefix .. " :: " .. tail_text) or (prefix .. tail_text)
      obuf.set_lines(bufnr, cur_line - 1, cur_line, { head, tail })
      if bullet.style == "numeric" then
        renumber(bufnr, cur_line + 1, bullet.indent, bullet.sep, bullet.n + 1)
      end
      move_to(cur_line + 1, #prefix)
      if enter_insert then
        vim.cmd("startinsert")
      end
      return
    end
    set_lines(bufnr, cur_line, { bullet.desc and (prefix .. " :: ") or prefix })
    if bullet.style == "numeric" then
      renumber(bufnr, cur_line + 1, bullet.indent, bullet.sep, bullet.n + 1)
    end
    move_to(cur_line + 1, #prefix)
    if enter_insert then
      vim.cmd(bullet.desc and "startinsert" or "startinsert!")
    end
    return
  end

  -- 3. Table row → new row below (mirrors the column count).  With
  -- opts.todo a row makes no sense; fall through to the body-line
  -- heading behavior instead (Emacs splits the table there, which
  -- organ's no-split convention deliberately avoids).
  if is_table_row(txt) and not opts.todo then
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
  local hl_line, hl_lvl = enclosing_headline(bufnr, cur_line)
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
    local kw = todo_keyword(get_line(bufnr, hl_line))
    local heading_prefix = string.rep("*", hl_lvl) .. " " .. (kw and (kw .. " ") or "")
    set_lines(bufnr, end_line, { heading_prefix })
    local spacing = require("organ.spacing")
    local policy = spacing.resolve(bufnr)
    local heading_row = spacing.normalize_around(bufnr, end_line + 1, policy) or (end_line + 1)
    normalize_following_heading(bufnr, heading_row, policy)
    move_to(heading_row, #heading_prefix)
    if enter_insert then
      vim.cmd("startinsert!")
    end
    return
  end

  -- 5. No heading anywhere in the buffer: treat M-RET as "start
  -- outlining" and create a level-1 heading.  Truly-empty buffer
  -- (one blank line) becomes a single `* ` line; a buffer with
  -- preamble-only content gets `* ` appended at the end with the
  -- buffer's own spacing policy.
  local total = vim.api.nvim_buf_line_count(bufnr)
  local has_any_heading = false
  for i = 1, total do
    if headline_level(get_line(bufnr, i)) then
      has_any_heading = true
      break
    end
  end
  if not has_any_heading then
    local kw = todo_keyword(nil)
    local heading_prefix = "* " .. (kw and (kw .. " ") or "")
    if total == 1 and get_line(bufnr, 1) == "" then
      obuf.set_lines(bufnr, 0, 1, { heading_prefix })
      move_to(1, #heading_prefix)
    else
      set_lines(bufnr, total, { heading_prefix })
      local spacing = require("organ.spacing")
      local policy = spacing.resolve(bufnr)
      local heading_row = spacing.normalize_around(bufnr, total + 1, policy) or (total + 1)
      move_to(heading_row, #heading_prefix)
    end
    if enter_insert then
      vim.cmd("startinsert!")
    end
    return
  end

  -- 6. Fallback (preamble of a file that DOES have headings, no
  -- list/table context) — open a fresh blank line below like Vim's
  -- `o`; with opts.todo, a fresh TODO heading instead.
  local kw = todo_keyword(nil)
  local new = kw and ("* " .. kw .. " ") or ""
  set_lines(bufnr, cur_line, { new })
  move_to(cur_line + 1, #new)
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
  insert_todo = {
    fn = function()
      M.dispatch({ enter_insert = false, todo = true })
    end,
    desc = "Insert a new TODO heading / unchecked checkbox item for the cursor context (Emacs M-S-RET)",
  },
}

return M
