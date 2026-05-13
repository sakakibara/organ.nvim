-- Capture prefix-tree popup. Built-in by default; which-key takes over
-- via pcall when loaded.

local M = {}

local obuf = require("organ.buf")
local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return organ.config.capture or {}
end

-- Group templates by their first-char prefix relative to the current depth.
-- Returns { [first_char] = { templates...} }
local function group_by_prefix(templates, depth)
  local groups = {}
  for _, t in ipairs(templates) do
    if t.key and #t.key > depth then
      local ch = t.key:sub(depth + 1, depth + 1)
      groups[ch] = groups[ch] or {}
      table.insert(groups[ch], t)
    end
  end
  return groups
end

-- Highlight defaults.  `default = true` so colorscheme overrides win.
local function register_hls()
  vim.api.nvim_set_hl(0, "OrganCaptureTitle", { link = "Title", default = true, bold = true })
  vim.api.nvim_set_hl(0, "OrganCaptureKey", { link = "Special", default = true, bold = true })
  vim.api.nvim_set_hl(0, "OrganCaptureName", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "OrganCaptureMore", { link = "Comment", default = true, italic = true })
end

-- Sorted list of (key, label, hl_group_for_label) tuples, derived from
-- the per-prefix-char groups.  Keys with a single template show that
-- template's name; multi-template keys get a "<n> templates →" hint.
local function entries_for(groups)
  local rows = {}
  for ch, ts in pairs(groups) do
    if #ts == 1 then
      rows[#rows + 1] = { key = ch, label = ts[1].name, label_hl = "OrganCaptureName" }
    else
      rows[#rows + 1] = {
        key = ch,
        label = string.format("%d templates ->", #ts),
        label_hl = "OrganCaptureMore",
      }
    end
  end
  table.sort(rows, function(a, b)
    return a.key < b.key
  end)
  return rows
end

-- Render the popup.  Returns (bufnr, win) for cleanup.  Layout:
--
--   ╭─ Capture template ──────────╮
--   │   [t]  Task                 │
--   │   [n]  Note                 │
--   │   [w]  3 templates →        │
--   ╰─────────────────────────────╯
--
-- Highlights:
--   * Title in the border (OrganCaptureTitle)
--   * `[t]` key glyph (OrganCaptureKey)
--   * Template name / hint (OrganCaptureName / OrganCaptureMore)
--
-- Width auto-fits to content (clamped to `pop_cfg.max_width` when set,
-- else 60% of columns) so a few short templates render compactly
-- instead of a fixed 30% slab.
local function render(groups, depth, prefix_path)
  register_hls()
  local cfg = get_config()
  local pop_cfg = cfg.popup or {}

  local rows = entries_for(groups)
  local max_lines = pop_cfg.max_lines or 15
  local truncated = false
  if #rows > max_lines then
    while #rows > max_lines - 1 do
      table.remove(rows)
    end
    truncated = true
  end

  -- Build display lines.  `  [k]  Label` -- 2-space leading padding +
  -- bracketed key + 2 spaces + label.  Track per-line highlight ranges
  -- so we can apply them via extmarks after the buffer is set.
  local lines = {}
  local marks = {} -- { { line = 0-based, col = 0-based, len, hl } ... }
  local content_w = 0
  for _, r in ipairs(rows) do
    local prefix = "  ["
    local key_col = #prefix
    local key_len = #r.key
    local sep = "]  "
    local label_col = key_col + key_len + #sep
    local line = prefix .. r.key .. sep .. r.label
    lines[#lines + 1] = line
    marks[#marks + 1] = { line = #lines - 1, col = key_col, len = key_len, hl = "OrganCaptureKey" }
    marks[#marks + 1] = { line = #lines - 1, col = label_col, len = #r.label, hl = r.label_hl }
    if vim.fn.strdisplaywidth(line) > content_w then
      content_w = vim.fn.strdisplaywidth(line)
    end
  end
  if truncated then
    lines[#lines + 1] = "  …"
  end
  if #lines == 0 then
    lines[1] = "  (no templates)"
  end

  -- Title: 'Capture template' at depth 0; 'Capture: <prefix>' once
  -- the user has typed into a multi-key prefix.
  local title = pop_cfg.title or "Capture template"
  if prefix_path and prefix_path ~= "" then
    title = "Capture: " .. prefix_path
  end

  -- Width: max(content, title + 4 for border padding).
  local title_w = vim.fn.strdisplaywidth(title) + 4
  local width
  if pop_cfg.width and pop_cfg.width >= 1 then
    width = pop_cfg.width
  else
    width = math.max(content_w + 4, title_w)
    local max_w = pop_cfg.max_width
        and (pop_cfg.max_width >= 1 and pop_cfg.max_width or math.floor(
          vim.o.columns * pop_cfg.max_width
        ))
      or math.floor(vim.o.columns * 0.6)
    if width > max_w then
      width = max_w
    end
  end
  width = math.max(20, math.min(width, vim.o.columns - 4))
  local height = math.min(#lines, max_lines)

  -- Center the float horizontally; place vertically just below middle
  -- so it doesn't obscure the headline / cursor area.
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local bufnr = vim.api.nvim_create_buf(false, true)
  obuf.set_lines(bufnr, 0, -1, lines)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_add_highlight, bufnr, 0, m.hl, m.line, m.col, m.col + m.len)
  end
  vim.bo[bufnr].modifiable = false

  local win = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    border = pop_cfg.border or "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    style = "minimal",
    focusable = false,
    noautocmd = true,
  })
  pcall(function()
    vim.wo[win].winhl = "FloatTitle:OrganCaptureTitle"
  end)
  vim.cmd("redraw")
  return bufnr, win
end

-- Built-in popup loop.
local function builtin_open(templates, on_select)
  local depth = 0
  local subset = templates
  local prefix_path = ""
  while true do
    local groups = group_by_prefix(subset, depth)
    if next(groups) == nil then
      require("organ.notify").warn("no template at this prefix")
      return
    end
    local bufnr, win = render(groups, depth, prefix_path)
    local ch = vim.fn.getcharstr()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    if ch == "" or ch == "\27" then
      return
    end -- Esc / abort
    local hit = groups[ch]
    if not hit then
      require("organ.notify").warn("no template with key starting '" .. ch .. "'")
      return
    end
    -- Filter to templates that continue with this char at the right depth.
    local next_subset = {}
    for _, t in ipairs(hit) do
      next_subset[#next_subset + 1] = t
    end
    -- Check if a unique leaf exists at depth+1.
    local leaf
    for _, t in ipairs(next_subset) do
      if #t.key == depth + 1 then
        leaf = t
        break
      end
    end
    if leaf and #next_subset == 1 then
      on_select(leaf)
      return
    end
    subset = next_subset
    prefix_path = prefix_path == "" and ch or (prefix_path .. ch)
    depth = depth + 1
  end
end

-- Public entry point. Tries which-key; falls back to built-in.
function M.open(_ctx, on_select)
  local templates = (get_config().templates or {})
  local with_keys = {}
  for _, t in ipairs(templates) do
    if t.key then
      with_keys[#with_keys + 1] = t
    end
  end
  if #with_keys == 0 then
    require("organ.notify").warn("no capture templates have a key")
    return
  end

  local ok_wk, wk = pcall(require, "which-key")
  if ok_wk and wk and wk.show then
    local trigger = "<organ-capture-trigger>"
    local entries = {}
    for _, t in ipairs(with_keys) do
      entries[#entries + 1] = {
        trigger .. t.key,
        function()
          on_select(t)
        end,
        desc = t.name,
      }
    end
    local ok = pcall(function()
      wk.add(entries)
      wk.show({ keys = trigger })
    end)
    if ok then
      return
    end
  end

  builtin_open(with_keys, on_select)
end

return M
