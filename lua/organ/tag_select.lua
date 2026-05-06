-- Fast tag selection picker. Mirrors Emacs `org-fast-tag-selection-single-key`
-- (C-c C-q): pop a window listing every available tag with a single-key
-- shortcut; toggle tags; press <CR> to commit, <Esc>/q to cancel.
--
-- Tag sources (merged, deduped, in this order):
--   1. config.tags.alist — list of entries:
--        - "work"                     — tag name; key auto-derived
--        - { name = "work", key = "w" } — explicit
--        - ":newline"                 — visual line-break marker
--        - { startgroup = "context" } — open mutually-exclusive group
--        - { endgroup   = true }      — close mutually-exclusive group
--   2. tags already used on any headline in the current buffer (auto-key).
--
-- A tag inside a startgroup/endgroup pair is mutually exclusive with siblings
-- in the same group: selecting one deselects the others.

local M = {}

local function get_config()
  local ok, organ = pcall(require, "organ")
  if not ok or not organ.config then
    return {}
  end
  return organ.config.tags or {}
end

-- Walk the buffer and collect every tag already on a headline.
local function buffer_tags(bufnr)
  local seen, out = {}, {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, ln in ipairs(lines) do
    if ln:match("^%*+%s") then
      local tag_run = ln:match("^.-%s+(:[%w_@#%%]+:.*)$")
      if tag_run and tag_run:match("^:[%w_@#%%]+:[%w_@#%%:]*$") then
        for tag in tag_run:gmatch(":([%w_@#%%]+)") do
          if not seen[tag] then
            seen[tag] = true
            out[#out + 1] = tag
          end
        end
      end
    end
  end
  return out
end

-- Auto-derive a single-key shortcut. Walks the tag's characters first; falls
-- back to digits/symbols if all chars collide.
local function auto_key(tag, used)
  for i = 1, #tag do
    local c = tag:sub(i, i):lower()
    if c:match("[%w]") and not used[c] then
      return c
    end
  end
  for c in ("0123456789!@#$%%^&*"):gmatch(".") do
    if not used[c] then
      return c
    end
  end
  return nil
end

-- Normalise the alist into a flat sequence of items:
--   { kind = "tag",        name, key, group_id }
--   { kind = "newline" }
--   { kind = "startgroup", id, label }
--   { kind = "endgroup",   id }
local function normalise_alist(alist, buffer_extras)
  local items = {}
  local current_group = nil
  local next_group_id = 0
  local used_keys = {}
  local seen_tags = {}

  local function add_tag(name, key)
    if seen_tags[name] then
      return
    end
    seen_tags[name] = true
    if not key then
      key = auto_key(name, used_keys)
    end
    if key then
      used_keys[key] = true
    end
    items[#items + 1] = {
      kind = "tag",
      name = name,
      key = key,
      group_id = current_group,
    }
  end

  for _, entry in ipairs(alist or {}) do
    if type(entry) == "string" then
      if entry == ":newline" then
        items[#items + 1] = { kind = "newline" }
      else
        add_tag(entry, nil)
      end
    elseif type(entry) == "table" then
      if entry.startgroup ~= nil then
        next_group_id = next_group_id + 1
        current_group = next_group_id
        items[#items + 1] = {
          kind = "startgroup",
          id = current_group,
          label = type(entry.startgroup) == "string" and entry.startgroup or nil,
        }
      elseif entry.endgroup ~= nil then
        items[#items + 1] = { kind = "endgroup", id = current_group }
        current_group = nil
      elseif entry.name then
        add_tag(entry.name, entry.key)
      end
    end
  end

  for _, name in ipairs(buffer_extras or {}) do
    add_tag(name, nil)
  end

  return items
end

-- Render the items into display lines + a key→tag-index map.
local function render_lines(items, selected)
  local lines = {}
  local key_to_idx = {}
  local cur = ""
  local function flush()
    if cur ~= "" then
      lines[#lines + 1] = cur
      cur = ""
    end
  end

  for i, it in ipairs(items) do
    if it.kind == "newline" then
      flush()
    elseif it.kind == "startgroup" then
      flush()
      lines[#lines + 1] = string.format("{ %s", it.label and ("group: " .. it.label) or "group")
    elseif it.kind == "endgroup" then
      flush()
      lines[#lines + 1] = "}"
    elseif it.kind == "tag" then
      local mark = selected[it.name] and "[X]" or "[ ]"
      local key = it.key or "?"
      local cell = string.format(" %s %s  %-14s", mark, key, it.name)
      if #cur + #cell > 70 then
        flush()
      end
      cur = (cur == "") and cell or (cur .. cell)
      if it.key then
        key_to_idx[it.key] = i
      end
    end
  end
  flush()
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  [tag-key] toggle   <CR> commit   <Esc>/q cancel"
  return lines, key_to_idx
end

-- Toggle one tag, honoring mutually-exclusive group membership.
local function toggle(items, idx, selected)
  local it = items[idx]
  if not it or it.kind ~= "tag" then
    return
  end
  if selected[it.name] then
    selected[it.name] = nil
    return
  end
  if it.group_id then
    for _, sib in ipairs(items) do
      if sib.kind == "tag" and sib.group_id == it.group_id then
        selected[sib.name] = nil
      end
    end
  end
  selected[it.name] = true
end

-- Open the popup; call on_confirm({tag,...}) on <CR>, on_cancel() on <Esc>.
function M.open(bufnr, current_tags, on_confirm, on_cancel)
  local cfg = get_config()
  local extras = buffer_tags(bufnr)
  local items = normalise_alist(cfg.alist or {}, extras)
  local selected = {}
  for _, t in ipairs(current_tags or {}) do
    selected[t] = true
  end

  local pop_bufnr = vim.api.nvim_create_buf(false, true)
  local function refresh()
    local lines = render_lines(items, selected)
    vim.api.nvim_buf_set_lines(pop_bufnr, 0, -1, false, lines)
  end
  refresh()

  local lines = vim.api.nvim_buf_get_lines(pop_bufnr, 0, -1, false)
  local width = 0
  for _, l in ipairs(lines) do
    if vim.fn.strdisplaywidth(l) > width then
      width = vim.fn.strdisplaywidth(l)
    end
  end
  width = math.max(40, math.min(width + 2, vim.o.columns - 4))
  local height = math.min(#lines, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(pop_bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    border = "rounded",
    style = "minimal",
    title = " Set tags ",
    title_pos = "center",
  })

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
    pcall(vim.api.nvim_buf_delete, pop_bufnr, { force = true })
  end

  while true do
    vim.cmd("redraw")
    local ch = vim.fn.getcharstr()
    if ch == "" or ch == "\27" or ch == "q" then -- Esc / q
      close()
      if on_cancel then
        on_cancel()
      end
      return
    end
    if ch == "\r" or ch == "\n" then
      close()
      local out = {}
      for _, it in ipairs(items) do
        if it.kind == "tag" and selected[it.name] then
          out[#out + 1] = it.name
        end
      end
      table.sort(out)
      on_confirm(out)
      return
    end
    -- Match a tag-key
    local _, key_to_idx = render_lines(items, selected)
    local idx = key_to_idx[ch]
    if idx then
      toggle(items, idx, selected)
      refresh()
    end
  end
end

-- Internal helpers exposed for tests.
M._normalise_alist = normalise_alist
M._auto_key = auto_key
M._render_lines = render_lines
M._toggle = toggle
M._buffer_tags = buffer_tags

-- High-level action: open the fast-tag-selection popup for the headline at
-- (`opts.bufnr`, `opts.line`); on confirm, write the new tags back via
-- tag_writer.  Both keys default to current buffer + cursor line.
function M.run(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line = opts.line or vim.fn.line(".")
  local writer = require("organ.tag_writer")
  local current = writer.read(bufnr, line)
  if not current then
    require("organ.notify").warn("no headline at or above cursor")
    return
  end
  M.open(bufnr, current.tags, function(new_tags)
    local err = writer.write(bufnr, line, new_tags)
    if err then
      require("organ.notify").error(err)
    end
  end)
end

M.commands = {
  set_tags = {
    fn = function()
      M.run()
    end,
    desc = "Open fast-tag-selection popup for the headline at cursor (Emacs C-c C-q)",
  },
}

return M
