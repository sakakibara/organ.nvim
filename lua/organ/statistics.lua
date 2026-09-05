-- Statistics cookies: `[N/M]` and `[XX%]` markers that auto-track progress.
--
-- Two contexts:
--   1. Headline cookie: top-level checkbox items of the lists in the
--      headline's section whenever the section holds a checkbox item at
--      any depth (org-update-checkbox-count), otherwise direct child
--      headlines whose TODO state is in the configured "done" set vs
--      child headlines that have any TODO state
--      (org-update-parent-todo-statistics). A `:COOKIE_DATA:` property
--      containing `todo` or `checkbox` forces the source; `recursive`
--      counts nested checkbox items too.
--   2. List-item cookie: checked vs total checkbox items among the item's
--      direct children.
--
-- Either form may use `[N/M]` (numerator/denominator) or `[XX%]` (floored
-- percent). Both forms cohabit: `Foo [1/3] [33%]` is valid and both update.

local M = {}

local obuf = require("organ.buf")
-- Sequence helpers (pulled from organ.todo so we don't depend on its module
-- loading inside every cookie update).

-- Returns the user's todo config (single or multi-sequence shape).
-- All consumers below pass through todo._normalise_sequences so both
-- shapes work and annotations are stripped.
local function todo_keywords()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config or not require("organ.buf_config").read(nil, "todo") then
    return { "TODO", "|", "DONE" }
  end
  return require("organ.buf_config").read(nil, "todo.sequences")
    or require("organ.buf_config").read(nil, "todo.sequence")
    or { "TODO", "|", "DONE" }
end

local function done_set(input)
  local set = {}
  for _, seq in ipairs(require("organ.todo")._normalise_sequences(input)) do
    local in_done = false
    for _, k in ipairs(seq) do
      if k == "|" then
        in_done = true
      elseif in_done then
        set[k] = true
      end
    end
  end
  return set
end

local function any_todo_kw(input)
  local set = {}
  for _, k in ipairs(require("organ.todo").all_keywords(input)) do
    set[k] = true
  end
  return set
end

-- Cookie patterns.

-- Match `[N/M]` and `[XX%]` cookies. Returns (kind, start_byte, end_byte)
-- iterator; kind is "fraction" or "percent".
local function cookies_in(line)
  local out = {}
  local pos = 1
  while true do
    local s, e = line:find("(%[(%d*)/(%d*)%])", pos)
    if s then
      out[#out + 1] = { kind = "fraction", s = s, e = e }
      pos = e + 1
    else
      break
    end
  end
  pos = 1
  while true do
    local s, e = line:find("(%[(%d*)%%%])", pos)
    if s then
      out[#out + 1] = { kind = "percent", s = s, e = e }
      pos = e + 1
    else
      break
    end
  end
  table.sort(out, function(a, b)
    return a.s < b.s
  end)
  return out
end

-- Headline cookie counts.

-- Walk descendants of headline at hl_line. For each direct child headline
-- (level == parent_level + 1) that carries a TODO state, count toward
-- denominator; if state is in done_set, count toward numerator.
--
-- `recursive = true` walks deeper than direct children (matches Emacs
-- `org-checkbox-hierarchical-statistics` for headlines).
local function count_children(lines, hl_line, opts)
  opts = opts or {}
  local seq = todo_keywords()
  local done = done_set(seq)
  local any = any_todo_kw(seq)

  local parent_stars = (lines[hl_line] or ""):match("^(%*+)%s") or ""
  local parent_level = #parent_stars
  if parent_level == 0 then
    return 0, 0
  end

  local total, done_n = 0, 0
  for i = hl_line + 1, #lines do
    local stars = (lines[i] or ""):match("^(%*+)%s")
    if stars then
      local lvl = #stars
      if lvl <= parent_level then
        break
      end
      local is_direct_child = (lvl == parent_level + 1)
      if opts.recursive or is_direct_child then
        local kw = (lines[i] or ""):match("^%*+%s+([A-Z][A-Z_]+)%s")
        if kw and any[kw] then
          total = total + 1
          if done[kw] then
            done_n = done_n + 1
          end
        end
      end
    end
  end
  return done_n, total
end

-- List-item cookie counts.

local function is_item(s)
  return (s or ""):match("^%s*[%-%+%*]%s") ~= nil or (s or ""):match("^%s*%d+[%.%)]%s") ~= nil
end

-- Returns the list-block range [s, e] (1-based) covering the line at `lnum`.
-- A list block is a contiguous run of list items at indent ≥ first item's
-- indent, optionally interrupted by continuation lines.  Rows inside a
-- verbatim block are raw text, so a `- ` there opens nothing.
local function list_block(lines, lnum, verbatim)
  if not is_item(lines[lnum]) then
    return nil, nil
  end
  local indent = (lines[lnum] or ""):match("^(%s*)") or ""
  local center_indent = #indent
  local s, e = lnum, lnum
  for i = lnum - 1, 1, -1 do
    if is_item(lines[i]) and not verbatim[i] then
      local ind = #((lines[i] or ""):match("^(%s*)") or "")
      if ind <= center_indent then
        s = i
      end
      if ind < center_indent then
        break
      end
    elseif (lines[i] or ""):match("^%s*$") then
      break
    else
      break
    end
  end
  for i = lnum + 1, #lines do
    local ln = lines[i] or ""
    local ind = #(ln:match("^(%s*)") or "")
    if is_item(ln) and not verbatim[i] then
      if ind < center_indent then
        break
      end
      e = i
    elseif ln:match("^%s*$") or ind <= center_indent then
      break
    end
  end
  return s, e
end

-- Indent and checkbox mark of a checkbox list item, or nil.
local function checkbox_item(line)
  local ind, mark = (line or ""):match("^(%s*)[%-%+%*]%s+%[([ Xx%-])%]")
  if not ind then
    ind, mark = (line or ""):match("^(%s*)%d+[%.%)]%s+%[([ Xx%-])%]")
  end
  if ind then
    return #ind, mark
  end
end

-- Checkbox items among the direct children of the list item at `lnum`
-- (every descendant when `recursive`).
local function count_checkboxes(lines, lnum, recursive, verbatim)
  local s, e = list_block(lines, lnum, verbatim)
  if not s then
    return 0, 0
  end
  local owner_indent = #((lines[lnum] or ""):match("^(%s*)") or "")
  local child_indent
  local total, checked = 0, 0
  for i = lnum + 1, e do
    local ind = #((lines[i] or ""):match("^(%s*)") or "")
    if ind <= owner_indent then
      break
    end
    if is_item(lines[i]) and not verbatim[i] then
      child_indent = child_indent or ind
      local _, mark = checkbox_item(lines[i])
      if mark and (recursive or ind == child_indent) then
        total = total + 1
        if mark == "X" or mark == "x" then
          checked = checked + 1
        end
      end
    end
  end
  return checked, total
end

-- Checkbox items in the section under the headline at `hl_line`, up to the
-- next headline of any level: the top-level items of each list, or every
-- item when `recursive` (org-update-checkbox-count).  The third return
-- reports whether the section holds a checkbox item at any depth.
local function count_section_checkboxes(lines, hl_line, recursive, verbatim)
  local total, checked = 0, 0
  local any_box = false
  local top_indent
  local blanks = 0
  for i = hl_line + 1, #lines do
    local ln = lines[i] or ""
    if ln:match("^%*+%s") then
      break
    end
    local ind = #(ln:match("^(%s*)") or "")
    if ln:match("^%s*$") then
      blanks = blanks + 1
      if blanks >= 2 then
        top_indent = nil
      end
    else
      blanks = 0
      if is_item(ln) and not (verbatim and verbatim[i]) then
        if not top_indent or ind < top_indent then
          top_indent = ind
        end
        local _, mark = checkbox_item(ln)
        if mark then
          any_box = true
          if recursive or ind == top_indent then
            total = total + 1
            if mark == "X" or mark == "x" then
              checked = checked + 1
            end
          end
        end
      elseif top_indent and ind <= top_indent then
        top_indent = nil
      end
    end
  end
  return checked, total, any_box
end

-- Lower-cased `:COOKIE_DATA:` of the headline at `hl_line`, or "".
local function cookie_data(bufnr, hl_line)
  for k, v in pairs(require("organ.element").properties_under(bufnr, hl_line - 1)) do
    if k:upper() == "COOKIE_DATA" then
      return tostring(v):lower()
    end
  end
  return ""
end

-- Cookie rewriting.

local function format_cookie(kind, num, den)
  if kind == "fraction" then
    return string.format("[%d/%d]", num, den)
  elseif kind == "percent" then
    if den == 0 then
      return "[0%]"
    end
    return string.format("[%d%%]", math.floor(num * 100 / den))
  end
  return ""
end

-- Update every cookie on `line` against (num, den). Returns the new line.
local function rewrite_cookies(line, num, den)
  local out = line
  -- fraction first then percent — order independent because patterns differ.
  out = out:gsub("%[(%d*)/(%d*)%]", function()
    return format_cookie("fraction", num, den)
  end)
  out = out:gsub("%[(%d*)%%%]", function()
    return format_cookie("percent", num, den)
  end)
  return out
end

-- Public API.

-- Update cookies for a single line (1-based) in bufnr. A headline cookie
-- counts section checkboxes when there are any, else TODO children;
-- `opts.mode = "todo"` counts TODO children regardless (the org-todo
-- path), unless `:COOKIE_DATA:` names a source. `opts.recursive` (or
-- `recursive` in COOKIE_DATA) counts nested items and headlines.
function M.update_line(bufnr, lnum, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- A `- [X]` inside a src or example block is text, not an item.
  local verbatim = opts.verbatim or require("organ.block").verbatim_rows(lines)
  local line = lines[lnum] or ""
  local cks = cookies_in(line)
  if #cks == 0 then
    return false
  end

  local num, den
  if line:match("^%*+%s") then
    local data = cookie_data(bufnr, lnum)
    local recursive = opts.recursive or data:find("recursive", 1, true) ~= nil
    local forced_checkbox = data:find("checkbox", 1, true) ~= nil
    local use_todo = data:find("todo", 1, true) ~= nil
      or (opts.mode == "todo" and not forced_checkbox)
    local any_box
    if not use_todo then
      num, den, any_box = count_section_checkboxes(lines, lnum, recursive, verbatim)
    end
    if not den or (den == 0 and not forced_checkbox and not any_box) then
      num, den = count_children(lines, lnum, { recursive = recursive })
    end
  else
    num, den = count_checkboxes(lines, lnum, opts.recursive, verbatim)
  end
  local new = rewrite_cookies(line, num, den)
  if new ~= line then
    obuf.set_lines(bufnr, lnum - 1, lnum, { new })
    return true
  end
  return false
end

-- Update every cookie line in the buffer. Returns the number of lines
-- that changed.
function M.update_buffer(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n_changed = 0
  local shared = vim.tbl_extend("keep", opts or {}, {
    verbatim = require("organ.block").verbatim_rows(lines),
  })
  for i, ln in ipairs(lines) do
    if #cookies_in(ln) > 0 and not shared.verbatim[i] then
      if M.update_line(bufnr, i, shared) then
        n_changed = n_changed + 1
      end
    end
  end
  return n_changed
end

-- Helper called from todo state changes / checkbox toggles. Walks every
-- ancestor headline of `lnum` and updates each that carries a cookie.
-- A headline origin is a TODO change, so those cookies count TODO
-- children; a list-item origin is a checkbox toggle.
function M.update_ancestors(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local mode = (lines[lnum] or ""):match("^%*+%s") and "todo" or nil
  local i = lnum
  while i >= 1 do
    local ln = lines[i] or ""
    if ln:match("^%*+%s") and #cookies_in(ln) > 0 then
      M.update_line(bufnr, i, { mode = mode })
    end
    if ln:match("^%*+%s") then
      -- Climb to parent: find the previous headline with strictly fewer stars.
      local stars = #(ln:match("^(%*+)") or "")
      local parent
      for j = i - 1, 1, -1 do
        local pj = (lines[j] or ""):match("^(%*+)%s")
        if pj and #pj < stars then
          parent = j
          break
        end
      end
      if not parent then
        break
      end
      i = parent
    else
      i = i - 1
    end
  end
end

M.commands = {
  update_statistics = {
    fn = function()
      local n = M.update_buffer(0)
      require("organ.notify").info(("updated %d cookie line(s)"):format(n))
    end,
    desc = "Recompute every [N/M] and [%] cookie in the current buffer",
  },
}

return M
