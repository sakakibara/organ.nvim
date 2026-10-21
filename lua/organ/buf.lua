-- Buffer-write helpers that no-op when the new content is byte-identical
-- to the existing content.  Wrap `vim.api.nvim_buf_set_lines` and
-- `vim.api.nvim_buf_set_text` so an operation that produces unchanged
-- text doesn't:
--   * mark the buffer as `modified`
--   * push an undo entry
--   * fire on_lines / on_bytes attach callbacks
--
-- Use throughout organ instead of the raw nvim_buf_set_* APIs so that
-- "confirm deadline with the same date", "set property to its current
-- value", "rewrite tag block to identical tags", "formatter that
-- produces identical output", etc. all leave the buffer's modified
-- state untouched.

local M = {}

-- What a line is for pairing an old line with a new one: a heading by its
-- stars and title without TODO keyword (one of `keywords`), priority,
-- COMMENT, cookies and tags, a drawer or block by its name, anything else
-- a plain line.
local function element(line, keywords)
  local stars, rest = line:match("^(%*+)%s+(.*)$")
  if stars then
    rest = rest:gsub("%s+:[%w_@#%%:]+:%s*$", "")
    local first, after = rest:match("^(%S+)%s+(.*)$")
    if first and keywords[first] then
      rest = after
    end
    rest = rest:gsub("^%[#%w%]%s*", "", 1):gsub("^COMMENT%s*", "", 1)
    rest = rest:gsub("%[%d*/%d*%]", ""):gsub("%[%d*%%%]", "")
    return "h" .. #stars .. " " .. vim.trim(rest)
  end
  local drawer = line:match("^%s*:([%w_-]+):%s*$")
  if drawer then
    return "d " .. drawer:upper()
  end
  local block = line:match("^%s*#%+[bB][eE][gG][iI][nN]_(%S+)")
  if block then
    return "b " .. block:lower()
  end
  return "plain"
end

-- Rewrite one line in place by its changed span only, so extmarks on the
-- unchanged prefix (a heading's fold and reveal marks at col 0) stay.
local function set_line_text(bufnr, row, old, new)
  local p = 0
  local max = math.min(#old, #new)
  while p < max and old:byte(p + 1) == new:byte(p + 1) do
    p = p + 1
  end
  local q = 0
  while q < max - p and old:byte(#old - q) == new:byte(#new - q) do
    q = q + 1
  end
  vim.api.nvim_buf_set_text(bufnr, row, p, row, #old - q, { new:sub(p + 1, #new - q) })
end

-- Write `new_lines` (a list of strings) to the range [start, end_), changing
-- only the lines that differ (see `element` for how changed lines pair), so
-- unchanged text keeps its extmarks and fold state.  `bufnr` defaults to
-- the current buffer (0); indexing is not strict, as nvim_buf_set_lines
-- with strict_indexing false.  One call is one undo step.
function M.set_lines(bufnr, start, end_, new_lines)
  bufnr = bufnr or 0
  local count = vim.api.nvim_buf_line_count(bufnr)
  local s = start < 0 and count + start + 1 or math.min(start, count)
  local e = end_ < 0 and count + end_ + 1 or math.min(end_, count)
  s, e = math.max(s, 0), math.max(e, 0)
  if e < s then
    -- Raises "'start' is higher than 'end'", as a direct call does.
    vim.api.nvim_buf_set_lines(bufnr, start, end_, false, new_lines)
    return
  end
  local current = vim.api.nvim_buf_get_lines(bufnr, s, e, false)
  if vim.deep_equal(current, new_lines) then
    return
  end
  if s == 0 and e == count and #new_lines == 0 then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    return
  end
  local function text(lines)
    return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
  end
  local hunks =
    require("organ.compat").diff(text(current), text(new_lines), { result_type = "indices" })
  local keywords = {}
  local todo = require("organ.todo")
  for _, k in ipairs(todo.all_keywords(todo.effective_sequences(bufnr))) do
    keywords[k] = true
  end
  local first = true
  for i = #hunks, 1, -1 do
    local a_start, a_count, b_start, b_count = unpack(hunks[i])
    local row = s + (a_count > 0 and a_start - 1 or a_start)
    local replacement = {}
    for k = b_start, b_start + b_count - 1 do
      replacement[#replacement + 1] = new_lines[k]
    end
    if not first then
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent! undojoin")
      end)
    end
    first = false
    local paired = a_count == b_count
    if paired and a_count > 1 then
      for k = 0, a_count - 1 do
        if element(current[a_start + k], keywords) ~= element(replacement[k + 1], keywords) then
          paired = false
          break
        end
      end
    end
    if paired then
      for k = a_count - 1, 0, -1 do
        if k < a_count - 1 then
          pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd("silent! undojoin")
          end)
        end
        set_line_text(bufnr, row + k, current[a_start + k], replacement[k + 1])
      end
    else
      vim.api.nvim_buf_set_lines(bufnr, row, row + a_count, false, replacement)
    end
  end
end

-- Write `new_text` (a list of strings, one per line) to the byte range
-- [(sr, sc), (er, ec)).  Same no-op-on-equal contract as set_lines.
function M.set_text(bufnr, sr, sc, er, ec, new_text)
  bufnr = bufnr or 0
  local current = vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {})
  if vim.deep_equal(current, new_text) then
    return
  end
  vim.api.nvim_buf_set_text(bufnr, sr, sc, er, ec, new_text)
end

-- Show `path` in the current window.  A file already in the window is
-- left as it is: `:edit` of it fails with E37 when it is modified and
-- re-reads it, opening every fold, when it is not.
function M.visit(path)
  local function canonical(p)
    return vim.fn.resolve(vim.fn.fnamemodify(p, ":p"))
  end
  local current = vim.api.nvim_buf_get_name(0)
  if current ~= "" and canonical(current) == canonical(path) then
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

return M
