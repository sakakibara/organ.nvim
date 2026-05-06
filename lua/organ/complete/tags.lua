-- Tag completion source.
--
-- Trigger: cursor sits inside the trailing tag region of a headline
-- — `* TODO Foo  :tag1:tag2:|`. Detected by:
--   1. line is a headline (starts with one or more `*` + space)
--   2. cursor is preceded by a `:` that opens a tag slot (i.e., the
--      substring from the most recent space-then-`:` to the cursor
--      contains only [%w_@#%%-:] characters and ends right at cursor)
--
-- Pool: union of `tags.alist` (config), tags actually seen across
-- indexed headlines (de-duped), and the current buffer's headline
-- tags. Sorted by frequency-then-alpha so common tags surface first.

local M = {}

-- Returns the partial tag being typed, or nil when not in context.
-- The "partial" is the substring after the last `:` up to the cursor.
function M.cursor_partial(bufnr, row, col)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if row == nil or col == nil then
    local pos = vim.api.nvim_win_get_cursor(0)
    row = row or pos[1]
    col = col or pos[2]
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  if not line:match("^%*+ ") then
    return nil
  end
  local before = line:sub(1, col)
  -- Find the start of the trailing tag region: a run of `:tag:tag:`
  -- preceded by whitespace, ending at cursor. We accept the partial
  -- being typed as well — the LAST `:` before cursor opens the tag
  -- being completed.
  local tag_region = before:match("%s+(:[%w_@#%%:%-]*)$")
  if not tag_region then
    return nil
  end
  -- Partial = chars after the most recent `:`.
  local partial = tag_region:match(":([%w_@#%%-]*)$")
  return partial or ""
end

-- Collect tags from the SQLite index (frequency-counted) plus
-- config.tags.alist defaults.
local function pool_with_freq()
  local freq = {}
  -- 1. Tags from indexed headlines.
  local ok, q = pcall(require, "organ.query")
  if ok then
    local rows = q.headlines({})
    for _, r in ipairs(rows or {}) do
      for _, t in ipairs(r.tags or {}) do
        freq[t] = (freq[t] or 0) + 1
      end
    end
  end
  -- 2. Config.tags.alist — explicit user-declared tag dictionary.
  local cfg = (require("organ").config.tags or {}).alist or {}
  for _, entry in ipairs(cfg) do
    -- alist entries can be {name, key} pairs or bare strings.
    local name = type(entry) == "table" and entry[1] or entry
    if type(name) == "string" and name ~= "" then
      freq[name] = freq[name] or 0
    end
  end
  -- 3. Tag groups (parent tags).
  for parent in pairs((require("organ").config.tags or {}).groups or {}) do
    freq[parent] = freq[parent] or 0
  end
  return freq
end

function M.completion_items(partial)
  partial = (partial or ""):lower()
  local freq = pool_with_freq()
  local pairs_list = {}
  for name, n in pairs(freq) do
    if partial == "" or name:lower():find(partial, 1, true) then
      pairs_list[#pairs_list + 1] = { name = name, n = n }
    end
  end
  -- Most-used first; ties → alpha.
  table.sort(pairs_list, function(a, b)
    if a.n ~= b.n then
      return a.n > b.n
    end
    return a.name < b.name
  end)
  local items = {}
  for _, p in ipairs(pairs_list) do
    items[#items + 1] = {
      label = p.name,
      insertText = p.name .. ":",
      filterText = p.name,
      kind = "EnumMember",
      detail = p.n > 0 and ("used " .. p.n .. "×") or nil,
    }
  end
  return items
end

return M
