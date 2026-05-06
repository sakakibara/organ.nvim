-- Drawer-name completion source. Surfaces built-in drawer names
-- (PROPERTIES, LOGBOOK, CLOCK) plus any custom drawer names already in the
-- current buffer.
--
-- Trigger: cursor on a line whose prefix matches `^%s*:NAME-IN-PROGRESS$`
-- AND the line lives inside a headline's section (not on the headline
-- itself, not before the first headline). Matches both "creating a new
-- drawer" (typed `:LO`) and "completing a known one".

local M = {}

local BUILTINS = { "PROPERTIES", "LOGBOOK", "CLOCK" }

-- Walk backwards from `lnum` until we find the headline that owns it.
-- Returns true if such a headline exists (so we're INSIDE a section).
local function in_headline_body(bufnr, lnum)
  for i = lnum - 1, 1, -1 do
    local ln = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    if ln:match("^%*+%s") then
      return true
    end
  end
  return false
end

-- Extract the partial drawer name being typed. Returns "" when no trigger.
function M.cursor_partial(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local prefix = line:sub(1, col)
  local rest = line:sub(col + 1):gsub("%s+$", "")
  if rest ~= "" then
    return ""
  end
  -- `^%s*:NAME-CHARS$` — NAME may be empty (just typed `:`).
  local name = prefix:match("^%s*:([%w_]*)$")
  if not name then
    return ""
  end
  if not in_headline_body(bufnr, row) then
    return ""
  end
  return name
end

-- Collect every drawer name already used in the buffer.
local function buffer_drawer_names(bufnr)
  local seen, out = {}, {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, ln in ipairs(lines) do
    local name = ln:match("^%s*:([%w_]+):%s*$")
    if name and name ~= "END" then
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  return out
end

-- Completion items for the given partial query. Each item is shaped
-- compatibly with blink.cmp / nvim-cmp (label, insertText, filterText, kind).
-- The insertText completes the `:NAME` already typed and appends `:` so the
-- user's cursor lands right at the body line. (Note: insertText REPLACES
-- the partial, so the caller's range/textEdit handling should account for
-- this — for simple completion sources, the host engine usually replaces
-- the keyword automatically.)
function M.completion_items(partial)
  partial = (partial or ""):upper()
  local bufnr = vim.api.nvim_get_current_buf()
  local pool = {}
  local seen = {}
  local function add(name)
    if seen[name] then
      return
    end
    seen[name] = true
    pool[#pool + 1] = name
  end
  for _, n in ipairs(BUILTINS) do
    add(n)
  end
  for _, n in ipairs(buffer_drawer_names(bufnr)) do
    add(n)
  end

  local out = {}
  for _, name in ipairs(pool) do
    if partial == "" or name:upper():find(partial, 1, true) then
      out[#out + 1] = {
        label = ":" .. name .. ":",
        insertText = name .. ":", -- the `:` user typed stays; we add NAME:
        filterText = name,
        kind = "Property",
      }
    end
  end
  return out
end

return M
