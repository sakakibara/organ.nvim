-- Org column view (Emacs `org-columns` C-c C-x C-c).
--
-- Reads the `#+COLUMNS:` keyword (file-level) or the `:COLUMNS:` property
-- on a headline; opens a read-only buffer rendering the configured
-- properties as a tabular view, one row per headline of the (sub)tree.
--
-- Spec syntax (subset of Emacs):
--   "%WIDTH? PROPERTY (LABEL)? {SUMMARY}?"   space-separated columns
--   ITEM            -> headline title (with todo + tags trimmed)
--   TODO            -> todo state
--   TAGS / ALLTAGS  -> direct tags / inherited tags
--   PRIORITY        -> priority cookie
--   anything else   -> property name (PROPERTIES drawer or builtin)
--
-- Summary types (applied to non-leaf rows):
--   {+}   sum (integers / floats)
--   {:}   sum (HH:MM durations)
--   {min} {max} {mean}   numeric aggregates
--   omitted -> empty for non-leaves

local M = {}

-- Parse a #+COLUMNS string into a list of column specs.
-- Each spec: { width = N | nil, property = "STRING", label = "STRING" | nil,
--              summary = "STRING" | nil }
function M.parse_spec(s)
  local cols = {}
  if not s or s == "" then
    return cols
  end
  for token in s:gmatch("%S+") do
    if token:sub(1, 1) ~= "%" then
      -- Some entries can be space-separated continuations of the previous
      -- token (e.g. "(Estimated  Time)") — for v1 we only support compact
      -- tokens; users can always pre-process their #+COLUMNS string.
    else
      local body = token:sub(2)
      local width = body:match("^(%d+)")
      if width then
        body = body:sub(#width + 1)
      end
      local prop, rest = body:match("^([%w_@]+)(.*)$")
      if prop then
        local label = rest:match("^%((.-)%)") or nil
        if label then
          rest = rest:sub(#label + 3)
        end
        local summary = rest:match("^{(.-)}$") or nil
        cols[#cols + 1] = {
          width = width and tonumber(width) or nil,
          property = prop,
          label = label,
          summary = summary,
        }
      end
    end
  end
  return cols
end

-- Find the active #+COLUMNS or :COLUMNS: at the cursor's scope.
-- Search order: nearest ancestor with :COLUMNS: property, then file-level
-- #+COLUMNS keyword.
function M.find_spec(bufnr, hl_line)
  local element = require("organ.element")
  -- 1) Walk up from hl_line looking at properties drawers (TS-first).
  local val = hl_line and element.property_value_inherited(bufnr, hl_line - 1, "COLUMNS") or nil
  if val and val ~= "" then
    -- Reconstruct the headline-line that owns the COLUMNS property.
    -- For the regex fallback we also walked up linearly; for TS we can
    -- query headline_at again to find which ancestor.
    local h = element.headline_at(bufnr, hl_line - 1)
    while h do
      if (element.properties_under(bufnr, h.line_start) or {}).COLUMNS == val then
        return val, h.line_start + 1
      end
      local parent = h.node:parent()
      while parent and parent:type() ~= "headline" do
        parent = parent:parent()
      end
      if not parent then
        break
      end
      h = element.headline_at(bufnr, (parent:range()))
    end
    return val, nil
  end
  -- 2) File-level #+COLUMNS keyword.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      break
    end
    local v = ln:match("^%s*#%+COLUMNS:%s*(.-)%s*$")
    if v and v ~= "" then
      return v, nil
    end
  end
  return nil, nil
end

-- Read a single property value for a headline (line index 1-based).
-- Built-ins: ITEM, TODO, PRIORITY, TAGS. Otherwise reads from PROPERTIES drawer.
local function get_prop(lines, hl_line, prop_name)
  local heading = lines[hl_line] or ""
  if prop_name == "ITEM" then
    -- Strip stars + TODO + priority + tags.
    local body = heading:gsub("^%*+%s+", "")
    body = body:gsub("^[A-Z][A-Z_]*%s+", "")
    body = body:gsub("^%[#%w%]%s*", "")
    body = body:gsub("%s+:[%w_:@]+:%s*$", "")
    return body
  end
  if prop_name == "TODO" then
    local kw = heading:match("^%*+%s+([A-Z][A-Z_]+)%s") or ""
    return kw
  end
  if prop_name == "PRIORITY" then
    return heading:match("%[#(%w)%]") or ""
  end
  if prop_name == "TAGS" then
    local trail = heading:match("(:[%w_@#%%]+:)%s*$") or ""
    return trail
  end
  -- Custom property: read from PROPERTIES drawer via element.lua
  -- (TS-first; regex fallback inside the helper).
  local props =
    require("organ.element").properties_under(vim.api.nvim_get_current_buf(), hl_line - 1)
  if props[prop_name] then
    return props[prop_name]
  end
  -- Continue legacy regex path below for parser-not-loaded scratch buffers.
  local i = hl_line + 1
  while
    i <= #lines
    and (
      lines[i]:match("^%s*SCHEDULED:")
      or lines[i]:match("^%s*DEADLINE:")
      or lines[i]:match("^%s*CLOSED:")
      or lines[i]:match("^%s*$")
    )
  do
    i = i + 1
  end
  if lines[i] and lines[i]:match("^%s*:PROPERTIES:") then
    local k = i + 1
    while k <= #lines and not lines[k]:match("^%s*:END:") do
      local key, val = lines[k]:match("^%s*:([%w_]+):%s*(.-)%s*$")
      if key == prop_name then
        return val
      end
      k = k + 1
    end
  end
  return ""
end

-- Collect the rows in the (sub)tree starting at root_line (or whole file if nil).
-- Returns { { hl_line, level, values = { col_idx -> string } } }
function M.collect(bufnr, root_line, columns)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local rows = {}
  local root_level
  if root_line then
    local stars = (lines[root_line] or ""):match("^(%*+)")
    root_level = stars and #stars or 1
  end
  for i, ln in ipairs(lines) do
    local stars = ln:match("^(%*+)%s")
    if stars then
      local level = #stars
      local include = true
      if root_line then
        if i < root_line then
          include = false
        elseif i > root_line and level <= root_level then
          break
        end
      end
      if include then
        local values = {}
        for ci, col in ipairs(columns) do
          values[ci] = get_prop(lines, i, col.property)
        end
        rows[#rows + 1] = { hl_line = i, level = level, values = values }
      end
    end
  end
  return rows
end

-- Compute summary aggregates per column for non-leaf rows. For each row that
-- has descendants, compute summary[ci] from the descendant rows' values per
-- col[ci].summary.
local function parse_hm(s)
  if not s then
    return nil
  end
  local h, m = s:match("^(%d+):(%d+)$")
  if h and m then
    return tonumber(h) * 60 + tonumber(m)
  end
  return tonumber(s)
end

local function fmt_hm(mins)
  if not mins then
    return ""
  end
  return string.format("%d:%02d", math.floor(mins / 60), mins % 60)
end

local function aggregate(values_list, summary)
  if not summary or #values_list == 0 then
    return ""
  end
  local nums = {}
  for _, v in ipairs(values_list) do
    if summary == ":" then
      local n = parse_hm(v)
      if n then
        nums[#nums + 1] = n
      end
    else
      local n = tonumber(v)
      if n then
        nums[#nums + 1] = n
      end
    end
  end
  if #nums == 0 then
    return ""
  end
  if summary == "+" then
    local s = 0
    for _, n in ipairs(nums) do
      s = s + n
    end
    return tostring(s)
  end
  if summary == ":" then
    local s = 0
    for _, n in ipairs(nums) do
      s = s + n
    end
    return fmt_hm(s)
  end
  if summary == "min" then
    local m = nums[1]
    for _, n in ipairs(nums) do
      if n < m then
        m = n
      end
    end
    return tostring(m)
  end
  if summary == "max" then
    local m = nums[1]
    for _, n in ipairs(nums) do
      if n > m then
        m = n
      end
    end
    return tostring(m)
  end
  if summary == "mean" then
    local s = 0
    for _, n in ipairs(nums) do
      s = s + n
    end
    return string.format("%.2f", s / #nums)
  end
  return ""
end

-- For each row that has descendants AND any column with a summary spec,
-- replace empty values with the aggregate.
function M.apply_summaries(rows, columns)
  for i, row in ipairs(rows) do
    -- Find the descendant slice (rows with greater level until a row with
    -- level <= row.level appears).
    local children = {}
    for j = i + 1, #rows do
      if rows[j].level <= row.level then
        break
      end
      children[#children + 1] = rows[j]
    end
    if #children == 0 then -- leaf; nothing to do
    else
      for ci, col in ipairs(columns) do
        if col.summary and (row.values[ci] == "" or row.values[ci] == nil) then
          local vs = {}
          for _, c in ipairs(children) do
            vs[#vs + 1] = c.values[ci]
          end
          row.values[ci] = aggregate(vs, col.summary)
        end
      end
    end
  end
end

-- Render a tabular view as a list of lines.
function M.render(rows, columns)
  -- Compute column widths: max(label, declared width, content max).
  local widths = {}
  for ci, col in ipairs(columns) do
    local w = col.width or #(col.label or col.property)
    for _, row in ipairs(rows) do
      local v = row.values[ci] or ""
      if vim.fn.strdisplaywidth(v) > w then
        w = vim.fn.strdisplaywidth(v)
      end
    end
    widths[ci] = w
  end
  local function pad(s, w)
    return s .. string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s)))
  end

  local out = {}
  -- Header.
  local hdr_cells, sep_cells = {}, {}
  for ci, col in ipairs(columns) do
    hdr_cells[ci] = pad(col.label or col.property, widths[ci])
    sep_cells[ci] = string.rep("-", widths[ci])
  end
  out[#out + 1] = "| " .. table.concat(hdr_cells, " | ") .. " |"
  out[#out + 1] = "|-" .. table.concat(sep_cells, "-+-") .. "-|"
  for _, row in ipairs(rows) do
    local cells = {}
    for ci = 1, #columns do
      cells[ci] = pad(row.values[ci] or "", widths[ci])
    end
    out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end
  return out
end

-- Open a column-view buffer for the (sub)tree at cursor in `source_bufnr`.
-- If source_bufnr is omitted, use current buffer; if no headline at cursor,
-- show the whole file.
function M.open(source_bufnr, source_line)
  source_bufnr = source_bufnr or vim.api.nvim_get_current_buf()
  source_line = source_line or vim.api.nvim_win_get_cursor(0)[1]
  local spec, root_line = M.find_spec(source_bufnr, source_line)
  if not spec then
    require("organ.notify").warn(
      "no #+COLUMNS or :COLUMNS: visible from cursor; set one to use column view"
    )
    return
  end
  local columns = M.parse_spec(spec)
  if #columns == 0 then
    require("organ.notify").warn("column spec parsed to zero columns")
    return
  end
  local rows = M.collect(source_bufnr, root_line, columns)
  M.apply_summaries(rows, columns)
  local lines = M.render(rows, columns)

  local view_bufnr = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(view_bufnr, string.format("organ-columns://%d", view_bufnr))
  vim.bo[view_bufnr].filetype = "organ-columns"
  vim.bo[view_bufnr].buftype = "nofile"
  vim.bo[view_bufnr].swapfile = false
  vim.bo[view_bufnr].buflisted = false
  vim.api.nvim_buf_set_lines(view_bufnr, 0, -1, false, lines)
  vim.bo[view_bufnr].modifiable = false

  -- Save the row→source-line index so the jump keymap can navigate.
  vim.b[view_bufnr].organ_columns = {
    source_bufnr = source_bufnr,
    -- Header + divider take lines 1-2; row R lives on view-line 2+R.
    line_to_source = (function()
      local out = {}
      for ri, row in ipairs(rows) do
        out[2 + ri] = row.hl_line
      end
      return out
    end)(),
  }

  local function jump()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local map = (vim.b[view_bufnr].organ_columns or {}).line_to_source or {}
    local src = map[lnum]
    if not src then
      return
    end
    vim.api.nvim_set_current_buf(source_bufnr)
    vim.api.nvim_win_set_cursor(0, { src, 0 })
  end
  vim.api.nvim_buf_set_keymap(view_bufnr, "n", "<CR>", "", {
    noremap = true,
    silent = true,
    callback = jump,
    desc = "Jump to source",
  })
  vim.api.nvim_buf_set_keymap(view_bufnr, "n", "q", "", {
    noremap = true,
    silent = true,
    callback = function()
      vim.api.nvim_buf_delete(view_bufnr, { force = true })
    end,
    desc = "Close column view",
  })

  vim.api.nvim_set_current_buf(view_bufnr)
  require("organ.ui").set_winbar(vim.fn.bufwinid(view_bufnr), {
    { "<CR>", "jump to source" },
    { "q", "close" },
  }, { title = "Column view" })
  return view_bufnr
end

M.commands = {
  columns = {
    fn = function()
      M.open()
    end,
    desc = "Open column view for the (sub)tree at cursor (uses #+COLUMNS or :COLUMNS:)",
  },
}

return M
