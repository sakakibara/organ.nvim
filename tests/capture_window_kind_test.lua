-- Tests for config.capture.window.kind = "float" | "split" | "vsplit".
-- Run via: nvim --headless -l tests/capture_window_kind_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local target_path = tmp .. "/window_kind.org"
vim.fn.writefile({ "* Existing" }, target_path)

local function start_capture(win_kind)
  require("organ").setup({
    db_path = tmp .. "/wk.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
    capture = {
      templates = {}, -- no default templates needed
      window = {
        kind = win_kind,
        width = 0.6,
        height = 0.4,
        border = "rounded",
        title = "Capture: %s",
        title_pos = "center",
      },
    },
  })

  local capture = require("organ.capture")
  capture.start({
    name = "Test",
    target = { kind = "file", path = target_path },
    body = "* %?",
  }, {
    source_bufnr = 0,
    source_win = vim.api.nvim_get_current_win(),
    source_cursor = { 1, 0 },
    source_file = "",
    prompts = { text = {}, dates = {} },
    now = os.time(),
  })
  return vim.api.nvim_get_current_buf()
end

-- Helper: is the current window a floating window?
local function current_win_is_float()
  local cfg = vim.api.nvim_win_get_config(0)
  return cfg.relative ~= nil and cfg.relative ~= ""
end

-- 1. Default (float): window is a floating window.
do
  local bufnr = start_capture("float")
  assert(current_win_is_float(), "kind=float should open a floating window")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 2. kind=split: window is NOT a floating window (it is a split).
do
  local initial_wins = #vim.api.nvim_list_wins()
  local bufnr = start_capture("split")
  assert(not current_win_is_float(), "kind=split should NOT be a floating window")
  -- A new window should have been created.
  assert(#vim.api.nvim_list_wins() > initial_wins, "kind=split should create a new window split")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 3. kind=vsplit: window is NOT a floating window (it is a vsplit).
do
  local initial_wins = #vim.api.nvim_list_wins()
  local bufnr = start_capture("vsplit")
  assert(not current_win_is_float(), "kind=vsplit should NOT be a floating window")
  assert(#vim.api.nvim_list_wins() > initial_wins, "kind=vsplit should create a new window split")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 4. Default config has kind = "float".
do
  local defaults = require("organ.defaults")
  assert(
    defaults.capture.window.kind == "float",
    "default window.kind should be 'float'; got " .. tostring(defaults.capture.window.kind)
  )
end

vim.fn.delete(tmp, "rf")
io.write("capture window kind ok\n")
os.exit(0)
