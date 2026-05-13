-- :Org goto — fuzzy jump to a headline within the current buffer.
-- Mirrors Emacs `org-goto` (C-c C-j): pop a picker showing every headline by
-- outline path, jump on confirm, and ensure the path is unfolded so the
-- cursor lands on a visible line.
--
-- Headlines are collected from the current buffer's text (no DB needed), so
-- the picker is always in-sync with unsaved edits.

local M = {}

-- Walk the buffer and produce { { line, level, title, path = "A / B / C" }, ... }
-- where `path` is the slash-joined chain of ancestor titles INCLUDING this one.
-- Headline title / level decomposition is delegated to `element.headlines`,
-- which uses the tree-sitter `headline_line` field accessors (with a regex
-- fallback for parser-not-loaded paths).
function M.outline(bufnr)
  local headlines = require("organ.element").headlines(bufnr)
  local stack = {} -- ancestor titles by level
  local out = {}
  for _, h in ipairs(headlines) do
    stack[h.level] = h.title
    for j = h.level + 1, #stack do
      stack[j] = nil
    end
    local path_parts = {}
    for j = 1, h.level do
      path_parts[#path_parts + 1] = stack[j] or "?"
    end
    out[#out + 1] = {
      line = h.line_start + 1, -- 1-based line for picker display
      level = h.level,
      title = h.title,
      path = table.concat(path_parts, " / "),
    }
  end
  return out
end

local function build_items(bufnr)
  local rows = M.outline(bufnr)
  local items = {}
  for _, r in ipairs(rows) do
    items[#items + 1] = {
      kind = "buffer_headline",
      bufnr = bufnr,
      line_start = r.line - 1, -- 0-based for snacks.actions parity
      title = r.title,
      level = r.level,
      display = string.format("%d  %s", r.line, r.path),
      match = r.path,
    }
  end
  return items
end

local function unfold_to(bufnr, line)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end
  vim.cmd("normal! zv")
end

local function jump_action(item)
  if item.bufnr ~= vim.api.nvim_get_current_buf() then
    pcall(vim.api.nvim_set_current_buf, item.bufnr)
  end
  vim.api.nvim_win_set_cursor(0, { item.line_start + 1, 0 })
  unfold_to(item.bufnr, item.line_start + 1)
end

local function resolve_backend(spec)
  if type(spec) == "table" then
    return spec
  end
  local name = spec or "snacks"
  if name == "snacks" then
    return require("organ.find.backends.snacks")
  end
  local ok, mod = pcall(require, "organ.find.backend")
  if ok and mod[name] then
    return mod[name]
  end
  error("organ.goto: unknown backend '" .. tostring(name) .. "'")
end

-- Open the picker. opts.bufnr (default: current).
function M.open(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local items = build_items(bufnr)
  if #items == 0 then
    require("organ.notify").info("no headlines in buffer")
    return
  end
  local cfg = (require("organ.buf_config").read(nil, "find") or {})
  local backend = resolve_backend(opts.backend or cfg.backend or "snacks")
  backend.pick(items, {
    prompt = "Goto: ",
    default_action = "jump",
    actions = { jump = jump_action },
    keymaps = cfg.keymaps or {},
  })
end

M.commands = {
  -- `goto` is a Lua reserved word -- store under a string key.
  ["goto"] = {
    fn = function()
      M.open()
    end,
    desc = "Fuzzy jump to a headline within the current buffer (Emacs C-c C-j)",
  },
}

return M
