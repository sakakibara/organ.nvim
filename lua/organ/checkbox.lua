-- Checkbox toggling and statistics-cookie maintenance.
--
-- Compatibility with Emacs org-mode:
--   * Cycles `[ ]` → `[X]` → `[-]` → `[ ]` per `org-toggle-checkbox`.
--   * After every toggle the nearest enclosing list item with a
--     statistics cookie (`[N/M]` or `[P%]`) is recalculated from its
--     direct children.  Recursion propagates upward.
--   * Description lists (`- term :: definition`) are accepted as items.
--
-- This module is text-driven; it doesn't require the tree-sitter parser.

local M = {}

-- Cycle order: empty → done → partial → empty.  Matches Emacs's
-- `org-toggle-checkbox` default with `org-list-automatic-rules` enabled.
local CYCLE = { [" "] = "X", X = "-", ["-"] = " " }

-- A list item line with optional bullet, optional counter, optional
-- checkbox.  Returns:
--   indent       column index of bullet
--   bullet_end   column index of first byte AFTER bullet's trailing space
--   state        " " | "X" | "-" | nil  if no checkbox
--   state_col    column of the checkbox state char (0-based byte offset)
--   cookie_text  text of statistics cookie, or nil
--   cookie_col   start byte offset of cookie text, or nil
--   cookie_end   end   byte offset of cookie text, or nil
function M.parse_item_line(line)
  -- Match leading indent + bullet + space.
  local indent_chars, bullet_chars, after_bullet_pos
  local p = line:match("^(%s*)([-+]%s+)()")
  if p then
    indent_chars = #(line:match("^(%s*)"))
    bullet_chars = (line:match("^%s*([-+]%s+)"))
    after_bullet_pos = #(line:match("^(%s*[-+]%s+)"))
  else
    -- `*` bullet (only at indent > 0)
    local indent = line:match("^(%s+)") or ""
    if indent ~= "" then
      local m = line:match("^%s+(%*%s+)")
      if m then
        indent_chars = #indent
        bullet_chars = m
        after_bullet_pos = #indent + #m
      end
    end
  end

  if not after_bullet_pos then
    -- Numeric bullet: digits + `.`/`)` + space.
    local n = line:match("^%s*(%d+[%.%)]%s+)")
    if n then
      indent_chars = #(line:match("^(%s*)"))
      bullet_chars = n
      after_bullet_pos = #(line:match("^%s*%d+[%.%)]%s+"))
    end
  end

  if not after_bullet_pos then
    return nil
  end

  local rest = line:sub(after_bullet_pos + 1)
  local rest_offset = after_bullet_pos

  -- Optional counter `[@N] `
  local counter_len = 0
  local cm = rest:match("^(%[@%d+%]%s+)")
  if cm then
    counter_len = #cm
    rest = rest:sub(counter_len + 1)
    rest_offset = rest_offset + counter_len
  end

  -- Optional checkbox `[X] ` / `[ ] ` / `[-] `
  local cbx = rest:match("^%[([- xX])%]%s+")
  local state, state_col
  if cbx then
    state = (cbx == "x") and "X" or cbx
    state_col = rest_offset + 1 -- 0-based byte offset of the state char (after `[`)
  end

  -- Statistics cookie anywhere later in the line: `[N/M]` or `[P%]`.
  local cookie_text, ck_s, ck_e
  do
    local s, e, ct = line:find("(%[%d*/?%d*%%?%])", rest_offset)
    if
      s
      and ct
      and (
        ct:match("^%[%d+/%d+%]$")
        or ct:match("^%[%d+%%%]$")
        or ct:match("^%[/%]$")
        or ct:match("^%[%%%]$")
      )
    then
      cookie_text = ct
      ck_s = s - 1
      ck_e = e -- 0-based start, exclusive end
    end
  end

  return {
    indent = indent_chars,
    bullet_end_col = after_bullet_pos, -- 0-based exclusive
    state = state,
    state_col = state_col,
    cookie = cookie_text,
    cookie_start = ck_s,
    cookie_end = ck_e,
  }
end

-- Toggle the checkbox at `opts.line` of `opts.bufnr`.  Both default to the
-- current buffer + cursor line.  If the line has no checkbox but is a
-- bullet, inserts `[ ]` first; second invocation toggles to `[X]`.
-- Returns true on success.
function M.toggle(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local row = line - 1
  local txt = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local p = M.parse_item_line(txt)
  if not p then
    return false
  end

  local new_line
  if p.state then
    local new_state = CYCLE[p.state] or " "
    new_line = txt:sub(1, p.state_col) .. new_state .. txt:sub(p.state_col + 2)
  else
    -- Insert `[ ] ` right after the bullet (and any counter).
    local insert_col = p.bullet_end_col
    new_line = txt:sub(1, insert_col) .. "[ ] " .. txt:sub(insert_col + 1)
  end
  vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { new_line })

  M.update_parent_cookie(bufnr, line)
  -- Headline ancestor cookies (e.g. `* Project [1/3]`) also reflect
  -- checkbox progress when the user opts into that style.
  pcall(function()
    require("organ.statistics").update_ancestors(bufnr, line)
  end)
  return true
end

-- Find the parent list-item line of `child_line` (1-based).  The parent
-- is the nearest preceding list item whose indent is STRICTLY less than
-- the child's indent.  Returns the parent's 1-based line number, or nil
-- if the child is at top level.
local function find_parent_item(bufnr, child_line)
  local txt = vim.api.nvim_buf_get_lines(bufnr, child_line - 1, child_line, false)[1] or ""
  local child = M.parse_item_line(txt)
  if not child then
    return nil
  end
  for ln = child_line - 1, 1, -1 do
    local l = vim.api.nvim_buf_get_lines(bufnr, ln - 1, ln, false)[1] or ""
    if l:match("^%*+%s") then
      return nil
    end -- crossed a headline
    local p = M.parse_item_line(l)
    if p and p.indent < child.indent then
      return ln, p
    end
  end
  return nil
end

-- Walk forward from `start_line` collecting the direct children of the
-- list item whose indent column is `parent_indent`.  Returns list of
-- {line, parsed} for items at indent > parent_indent that have no
-- intermediate item at <= parent_indent.
local function direct_children(bufnr, start_line, parent_indent)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local out = {}
  local seen_child_indent = nil
  for ln = start_line + 1, total do
    local l = vim.api.nvim_buf_get_lines(bufnr, ln - 1, ln, false)[1] or ""
    if l:match("^%*+%s") then
      break
    end
    local p = M.parse_item_line(l)
    if p then
      if p.indent <= parent_indent then
        break
      end
      if not seen_child_indent then
        seen_child_indent = p.indent
      end
      if p.indent == seen_child_indent then
        out[#out + 1] = { line = ln, item = p }
      end
    end
  end
  return out
end

-- Recompute statistics cookie on the parent of `child_line`, if any,
-- and recurse upward.
function M.update_parent_cookie(bufnr, child_line)
  local parent_ln, parent = find_parent_item(bufnr, child_line)
  if not parent_ln or not parent.cookie then
    return
  end
  local kids = direct_children(bufnr, parent_ln, parent.indent)
  if #kids == 0 then
    return
  end
  local total, done = 0, 0
  for _, k in ipairs(kids) do
    if k.item.state then
      total = total + 1
      if k.item.state == "X" then
        done = done + 1
      end
    end
  end
  if total == 0 then
    return
  end

  local new_cookie
  if parent.cookie:match("/") then
    new_cookie = string.format("[%d/%d]", done, total)
  else
    -- Percent form
    local pct = math.floor((done / total) * 100 + 0.5)
    new_cookie = string.format("[%d%%]", pct)
  end

  local txt = vim.api.nvim_buf_get_lines(bufnr, parent_ln - 1, parent_ln, false)[1] or ""
  local new = txt:sub(1, parent.cookie_start) .. new_cookie .. txt:sub(parent.cookie_end + 1)
  if new ~= txt then
    vim.api.nvim_buf_set_lines(bufnr, parent_ln - 1, parent_ln, false, { new })
  end

  -- Optionally also flip the parent's own checkbox to `-` (partial),
  -- `X` (all done), or ` ` (none done).  Per Emacs's default behaviour.
  if parent.state then
    local new_state = (done == total) and "X" or (done == 0) and " " or "-"
    if new_state ~= parent.state then
      local refreshed = vim.api.nvim_buf_get_lines(bufnr, parent_ln - 1, parent_ln, false)[1] or ""
      local p2 = M.parse_item_line(refreshed)
      if p2 and p2.state and p2.state_col then
        local nl = refreshed:sub(1, p2.state_col) .. new_state .. refreshed:sub(p2.state_col + 2)
        vim.api.nvim_buf_set_lines(bufnr, parent_ln - 1, parent_ln, false, { nl })
      end
    end
  end

  -- Recurse upward.
  M.update_parent_cookie(bufnr, parent_ln)
end

M.commands = {
  toggle_checkbox = {
    fn = function()
      if not M.toggle() then
        require("organ.notify").warn("not on a list item")
      end
    end,
    desc = "Cycle the checkbox on the current list item",
  },
}

return M
