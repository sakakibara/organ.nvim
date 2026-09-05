-- Org indentexpr. Returns, for a line, the same indent the formatter
-- produces: 0 for a headline, the section indent (planning_indent,
-- default level+1) for a headline-data line (planning / property drawer /
-- logbook), and -1 (keep current) for body text -- or that same section
-- indent for body when indent.adapt_indentation is on. So == / o /
-- auto-indent agree with :Org format by construction.

local M = {}

local function is_headline(l)
  return l:match("^%*+ ") ~= nil
end
local function is_planning(l)
  return l:match("^%s*[Ss][Cc][Hh][Ee][Dd][Uu][Ll][Ee][Dd]:") ~= nil
    or l:match("^%s*[Dd][Ee][Aa][Dd][Ll][Ii][Nn][Ee]:") ~= nil
    or l:match("^%s*[Cc][Ll][Oo][Ss][Ee][Dd]:") ~= nil
end
local function is_drawer_open(l)
  return l:match("^%s*:[%w_-]+:%s*$") ~= nil
end
local function is_drawer_close(l)
  return l:match("^%s*:[Ee][Nn][Dd]:%s*$") ~= nil
end
local function is_block_open(l)
  return l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") ~= nil
end
local function is_block_close(l)
  return l:match("^%s*#%+[Ee][Nn][Dd]_") ~= nil
end

local function line_at(bufnr, lnum)
  return (vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false) or {})[1] or ""
end

-- Indent (number of columns) for 1-based `lnum`, or -1 (keep current).
function M.compute(bufnr, lnum)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local line = line_at(bufnr, lnum)
  if is_headline(line) then
    return 0
  end
  local hl = require("organ.element_cache").containing(bufnr, lnum)
  if not hl then
    return -1
  end
  local in_drawer, in_block = false, false
  for r = hl.line + 1, lnum - 1 do
    local t = line_at(bufnr, r)
    if is_block_open(t) then
      in_block = true
    elseif is_block_close(t) then
      in_block = false
    elseif not in_block then
      if is_drawer_close(t) then
        in_drawer = false
      elseif is_drawer_open(t) then
        in_drawer = true
      end
    end
  end
  if in_block then
    return -1
  end
  if is_planning(line) or is_drawer_open(line) or is_drawer_close(line) or in_drawer then
    return #require("organ.section").planning_indent(bufnr, hl.line - 1)
  end
  if line:match("^%s*$") then
    return -1
  end
  local icfg = require("organ.buf_config").read(bufnr, "indent") or {}
  if icfg.adapt_indentation == true then
    -- Body prose indents to the same section column as the drawers above
    -- it (Emacs `org-adapt-indentation = t`: everything to `stars + 1`).
    return #require("organ.section").planning_indent(bufnr, hl.line - 1)
  end
  return -1
end

-- indentexpr entry: never throws (a thrown error spams every keystroke).
function M.expr()
  local ok, indent = pcall(M.compute, vim.api.nvim_get_current_buf(), vim.v.lnum)
  if ok and type(indent) == "number" then
    return indent
  end
  return -1
end

return M
