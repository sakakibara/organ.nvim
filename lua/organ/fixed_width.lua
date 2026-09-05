-- Fixed-width (`: `) markup toggle -- Emacs org-toggle-fixed-width (C-c :).
--
-- Line-based, like the formatter and list structure: a fixed-width line
-- is `: text` (or a bare `:`), and the toggle either strips that prefix
-- or adds it.  A region turns entirely into fixed-width lines unless it
-- already holds nothing but fixed-width and blank lines, in which case
-- it is stripped.

local M = {}

local obuf = require("organ.buf")

local FIXED = "^([ \t]*):( ?)"

-- Is `text` a fixed-width line (`: body`, or a bare `:`)?
local function is_fixed(text)
  return text:match("^[ \t]*: ") ~= nil or text:match("^[ \t]*:$") ~= nil
end

local function is_blank(text)
  return text:match("^%s*$") ~= nil
end

-- Strip the fixed-width prefix.  Emacs replaces the whole match --
-- indentation included -- when the marker runs to end of line, and only
-- the `: ` when body text follows.
local function strip(text)
  local indent, space = text:match(FIXED)
  if not indent then
    return text
  end
  local consumed = #indent + 1 + #space
  if consumed >= #text then
    return ""
  end
  return indent .. text:sub(consumed + 1)
end

-- Rows (1-based) whose content org reads as raw text or as a non-
-- paragraph element, where a fixed-width line cannot be inserted:
-- verbatim block bodies, drawer bodies, table rows and list items.
local function blocked_rows(lines)
  local rows = require("organ.block").verbatim_rows(lines)
  local in_drawer = false
  for i, l in ipairs(lines) do
    if in_drawer then
      rows[i] = true
      if l:match("^%s*:[Ee][Nn][Dd]:%s*$") then
        in_drawer = false
      end
    elseif l:match("^%s*:[%a][%w_-]*:%s*$") and not l:match("^%s*:[Ee][Nn][Dd]:%s*$") then
      rows[i] = true
      in_drawer = true
    end
  end
  return rows
end

local function cannot_insert(lines, row)
  local text = lines[row] or ""
  if blocked_rows(lines)[row] then
    return true
  end
  if text:match("^%s*|") then
    return true
  end
  if require("organ.list").parse_item(text) then
    return true
  end
  return false
end

-- Leading-whitespace width of `text` measured in columns, tabs expanded
-- to the buffer's tabstop the way org counts indentation.
local function indent_of(text)
  return #(text:match("^([ \t]*)") or "")
end

-- Toggle fixed-width markup over [line1, line2] (1-based, inclusive).
-- A single line follows Emacs's no-region branch; a multi-line range
-- follows its region branch.  Returns nil on success or an error string.
function M.toggle(bufnr, line1, line2)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(bufnr)
  line1 = math.max(1, math.min(line1, total))
  line2 = math.max(line1, math.min(line2 or line1, total))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  if line1 == line2 then
    local text = lines[line1] or ""
    local new
    if is_fixed(text) then
      new = strip(text)
    elseif is_blank(text) then
      if cannot_insert(lines, line1) then
        return "cannot insert a fixed-width line here"
      end
      new = ": "
    else
      if cannot_insert(lines, line1) then
        return "cannot insert a fixed-width line here"
      end
      local indent = text:match("^([ \t]*)")
      new = indent .. ": " .. text:sub(#indent + 1)
    end
    obuf.set_lines(bufnr, line1 - 1, line1, { new })
    return nil
  end

  -- Region: trailing blank lines are ignored unless the region holds
  -- nothing else.
  local last = line2
  while last > line1 and is_blank(lines[last] or "") do
    last = last - 1
  end
  if last == line1 and is_blank(lines[line1] or "") then
    last = line2
  end

  local all_fixed, any_content = true, false
  for i = line1, last do
    local text = lines[i] or ""
    if not is_blank(text) then
      any_content = true
      if not is_fixed(text) then
        all_fixed = false
      end
    end
  end

  local out = {}
  if any_content and all_fixed then
    for i = line1, last do
      out[#out + 1] = strip(lines[i] or "")
    end
  else
    local min_ind
    for i = line1, last do
      local text = lines[i] or ""
      if not is_blank(text) then
        local ind = indent_of(text)
        min_ind = math.min(min_ind or ind, ind)
      end
    end
    min_ind = min_ind or 0
    -- Emacs marks blank lines that immediately follow a headline with a
    -- bare `:` rather than `: `.
    local after_heading = false
    for i = line1, last do
      local text = lines[i] or ""
      if is_fixed(text) then
        out[#out + 1] = text
        after_heading = false
      elseif text:match("^%*+%s") or text:match("^%*+$") then
        out[#out + 1] = ": " .. text
        after_heading = true
      elseif after_heading and is_blank(text) then
        out[#out + 1] = ":"
      else
        after_heading = false
        local padded = text
        if #text < min_ind then
          padded = text .. string.rep(" ", min_ind - #text)
        end
        out[#out + 1] = padded:sub(1, min_ind) .. ": " .. padded:sub(min_ind + 1)
      end
    end
  end
  obuf.set_lines(bufnr, line1 - 1, last, out)
  return nil
end

M.commands = {
  toggle_fixed_width = {
    fn = function(cmd)
      local bufnr = vim.api.nvim_get_current_buf()
      local l1, l2
      if cmd and cmd.range and cmd.range > 0 then
        l1, l2 = cmd.line1, cmd.line2
      else
        l1 = vim.api.nvim_win_get_cursor(0)[1]
        l2 = l1
      end
      local err = M.toggle(bufnr, l1, l2)
      if err then
        require("organ.notify").warn(err)
      end
    end,
    range = true,
    desc = "Toggle the `: ` fixed-width prefix on the line or range (Emacs C-c :)",
  },
}

return M
