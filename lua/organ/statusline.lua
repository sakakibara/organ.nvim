-- Composable statusline / winbar elements for organ-owned buffers.
--
-- All functions take a bufnr (defaults to current buffer) and return a
-- string suitable for use inside a `statusline` / `winbar` expression.
-- Users can compose their own line by calling these directly:
--
--   vim.wo.winbar = "%{v:lua.require'organ.statusline'.view_name(0)}"
--
-- Or override the agenda's defaults wholesale:
--
--   require("organ").setup({ agenda = {
--     winbar     = function(bufnr) return ... end,  -- function form
--     statusline = "%{v:lua...}",                    -- string form
--     winbar     = false,                            -- disable
--   }})
--
-- Defaults install BUFFER-LOCAL (window-local for winbar) values only on
-- organ-owned buffers (agenda, backlinks, find pickers). The user's
-- global `vim.o.winbar` / `vim.o.statusline` are NEVER touched.

local M = {}

-- Element accessors. Each takes a bufnr and returns a plain string.

-- Display the agenda view name set on the buffer (e.g. "today", "todos",
-- "default"). Returns "" if not an agenda buffer.
function M.view_name(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local s = vim.b[bufnr].organ_agenda
  if type(s) ~= "table" then
    return ""
  end
  return s.view_name or s.name or "agenda"
end

-- Number of headlines / rows currently in the agenda view (sum across
-- all blocks). Returns "0" when the buffer has no row index yet.
function M.entry_count(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local s = vim.b[bufnr].organ_agenda
  if type(s) ~= "table" or type(s.line_index) ~= "table" then
    return "0"
  end
  local n = 0
  -- vim.b roundtrips nil values as `vim.NIL` (userdata, truthy in Lua).
  -- Only count entries that are real row tables.
  for _, r in pairs(s.line_index) do
    if type(r) == "table" then
      n = n + 1
    end
  end
  return tostring(n)
end

-- Date range covered by the view, e.g. "Sun 3 May → Sat 9 May 2026".
-- Returns "" when the view isn't time-windowed (todo list, etc.).
function M.date_range(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local s = vim.b[bufnr].organ_agenda
  if type(s) ~= "table" or not s.window then
    return ""
  end
  local from, to = s.window.from, s.window.to
  if not from then
    return ""
  end
  if from == to then
    return from
  end
  return from .. " → " .. (to or "")
end

-- Active title-substring filter (set via `/` keymap), or "".
function M.active_filter(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local s = vim.b[bufnr].organ_agenda
  if type(s) ~= "table" then
    return ""
  end
  return s.title_filter or ""
end

-- Buffer kind label (used for the Emacs-style `[Agenda: ...]` prefix).
-- Recognises agenda / backlinks / find buffers via vim.b.organ_* state.
function M.buffer_kind(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if vim.b[bufnr].organ_agenda then
    return "Agenda"
  end
  if vim.b[bufnr].organ_backlinks then
    return "Backlinks"
  end
  if vim.b[bufnr].organ_find then
    return "Find"
  end
  return ""
end

-- Default composers.

-- Agenda default winbar:
--   "[Agenda: today]  Sun 3 May → Sat 9 May 2026  ·  5 entries[  ·  filter: X]"
function M.agenda_winbar(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local parts = {}
  parts[#parts + 1] = "%#OrganStatusKind#[Agenda: " .. M.view_name(bufnr) .. "]%*"
  local range = M.date_range(bufnr)
  if range ~= "" then
    parts[#parts + 1] = "  " .. range
  end
  parts[#parts + 1] = "  ·  " .. M.entry_count(bufnr) .. " entries"
  local f = M.active_filter(bufnr)
  if f ~= "" then
    parts[#parts + 1] = "  ·  filter: " .. f
  end
  return table.concat(parts)
end

-- Agenda default statusline: tight one-line keymap reference.
function M.agenda_statusline(_bufnr)
  return "%#OrganStatusKey#<CR>%* jump  %#OrganStatusKey#t%* TODO  "
    .. "%#OrganStatusKey#s/D%* sched/dl  %#OrganStatusKey#I/O%* clock  "
    .. "%#OrganStatusKey#R%* refile  %#OrganStatusKey#/%* filter  "
    .. "%#OrganStatusKey#g?%* help"
end

function M.backlinks_winbar(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local s = vim.b[bufnr].organ_backlinks or {}
  local target = (s.target and s.target.title) or "(unknown)"
  local count = (s.line_index and #s.line_index) or 0
  return "%#OrganStatusKind#[Backlinks]%*  → " .. target .. "  ·  " .. count .. " incoming"
end

function M.backlinks_statusline(_bufnr)
  return "%#OrganStatusKey#<CR>%* jump  %#OrganStatusKey#gs/gv%* split/vsplit  "
    .. "%#OrganStatusKey#r%* refresh  %#OrganStatusKey#q%* close  "
    .. "%#OrganStatusKey#g?%* help"
end

-- Resolve helper: turn a config value into the string to set.
--
-- A config value can be:
--   * false                — disable (return nil; caller skips the set)
--   * nil OR true          — use the supplied default function
--   * string               — use the user-provided literal (statusline expr)
--   * function(bufnr) -> s — call it now and use the returned string
--
-- Returns (resolved_string_or_nil, error_string_or_nil).
function M.resolve(value, default_fn, bufnr)
  if value == false then
    return nil
  end
  if value == nil or value == true then
    return "%!v:lua.require'organ.statusline'." .. default_fn .. "(" .. bufnr .. ")"
  end
  if type(value) == "string" then
    return value
  end
  if type(value) == "function" then
    local ok, s = pcall(value, bufnr)
    if not ok then
      return nil, "user statusline/winbar function errored: " .. tostring(s)
    end
    return s
  end
  return nil, "unsupported statusline/winbar value: " .. type(value)
end

-- Apply window-local winbar and buffer-local statusline. Buffer / window
-- scope only — the user's global vim.o.winbar / vim.o.statusline are
-- never touched. Returns true on success.
function M.apply(bufnr, opts)
  opts = opts or {}
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return false
  end

  -- Highlight defaults (default = true so user's colorscheme wins).
  vim.api.nvim_set_hl(0, "OrganStatusKind", { link = "Title", default = true, bold = true })
  vim.api.nvim_set_hl(0, "OrganStatusKey", { link = "Special", default = true, bold = true })

  -- Treat `winbar = nil` as "use default" (the caller wired up a default
  -- by passing `winbar_default`). The user can pass `winbar = false`
  -- explicitly to disable.
  -- Use nvim_set_option_value with explicit scope = "local" so we never
  -- accidentally leak to the global value of these (notionally global-or-
  -- local) options. This guarantee is the whole point of `apply`.
  -- No-surprises rule: nil means "leave the user's value alone". The user
  -- must explicitly opt in by setting `winbar = true` (or a string /
  -- function). false also means "leave alone" (kept for symmetry with
  -- explicit-disable code paths).
  local function should_apply(v)
    return v == true or type(v) == "string" or type(v) == "function"
  end
  if opts.winbar_default and should_apply(opts.winbar) then
    local s, err = M.resolve(opts.winbar, opts.winbar_default, bufnr)
    if err then
      require("organ.notify").warn(err)
    end
    if s then
      pcall(vim.api.nvim_set_option_value, "winbar", s, { scope = "local", win = winid })
    end
  end
  if opts.statusline_default and should_apply(opts.statusline) then
    local s, err = M.resolve(opts.statusline, opts.statusline_default, bufnr)
    if err then
      require("organ.notify").warn(err)
    end
    if s then
      pcall(vim.api.nvim_set_option_value, "statusline", s, { scope = "local", win = winid })
    end
  end
  return true
end

-- lualine integration. Each element returns a lualine component table —
-- a function (the value provider) plus a `cond` that gates display to
-- organ-owned buffers so the component disappears in regular files.
--
-- Usage in a user's lualine config:
--
--   local org = require("organ.statusline").lualine
--   require("lualine").setup({
--     sections = {
--       lualine_a = { org.kind() },                  -- "[Agenda: today]"
--       lualine_b = { org.entries(), org.range() },  -- "5 entries", "Sun → Sat"
--       lualine_c = { org.filter() },                -- "filter: tag:work"
--     },
--   })
--
-- All components are no-args: lualine evaluates them on every redraw and
-- the current buffer is whatever the active window holds. Each `cond`
-- prevents the component from rendering in non-organ buffers.

M.lualine = {}

local function in_kind(kind)
  return function()
    return M.buffer_kind() == kind
  end
end
local function in_any_kind()
  return function()
    return M.buffer_kind() ~= ""
  end
end

function M.lualine.kind(opts)
  opts = opts or {}
  return vim.tbl_extend("force", {
    function()
      local k = M.buffer_kind()
      if k == "" then
        return ""
      end
      if k == "Agenda" then
        return "[Agenda: " .. M.view_name() .. "]"
      end
      return "[" .. k .. "]"
    end,
    cond = in_any_kind(),
  }, opts)
end

function M.lualine.entries(opts)
  opts = opts or {}
  return vim.tbl_extend("force", {
    function()
      return M.entry_count() .. " entries"
    end,
    cond = in_kind("Agenda"),
  }, opts)
end

function M.lualine.range(opts)
  opts = opts or {}
  return vim.tbl_extend("force", {
    function()
      return M.date_range()
    end,
    cond = function()
      return M.buffer_kind() == "Agenda" and M.date_range() ~= ""
    end,
  }, opts)
end

function M.lualine.filter(opts)
  opts = opts or {}
  return vim.tbl_extend("force", {
    function()
      local f = M.active_filter()
      return f ~= "" and ("filter: " .. f) or ""
    end,
    cond = function()
      return M.buffer_kind() == "Agenda" and M.active_filter() ~= ""
    end,
  }, opts)
end

function M.lualine.backlinks_target(opts)
  opts = opts or {}
  return vim.tbl_extend("force", {
    function()
      local s = vim.b.organ_backlinks
      return (s and s.target and s.target.title) or ""
    end,
    cond = in_kind("Backlinks"),
  }, opts)
end

return M
