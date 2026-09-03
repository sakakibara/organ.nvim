-- Tests for capture.cancel — modified-buffer confirmation flow.
-- Run via: nvim --headless -l tests/capture_cancel_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local target_path = tmp .. "/inbox.org"
vim.fn.writefile({ "* Existing" }, target_path)

require("organ").setup({
  db_path = tmp .. "/c.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local capture = require("organ.capture")

local function start_template()
  capture.start({
    name = "X",
    target = { kind = "file", path = target_path },
    body = "* X %?",
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

-- 1. Unmodified buffer: cancel closes silently, no prompt.
do
  local bufnr = start_template()
  vim.bo[bufnr].modified = false

  local prompted
  local original = vim.ui.input
  vim.ui.input = function(_o, cb)
    prompted = true
    cb("y")
  end

  capture.cancel(bufnr)

  vim.ui.input = original
  assert(not prompted, "should NOT prompt when unmodified")
  assert(not vim.api.nvim_buf_is_valid(bufnr), "buffer should be closed")
end

-- 2. Modified buffer + "y" response: closes.
do
  local bufnr = start_template()
  vim.bo[bufnr].modified = true

  local original = vim.ui.input
  vim.ui.input = function(_o, cb)
    cb("y")
  end

  capture.cancel(bufnr)

  vim.ui.input = original
  assert(not vim.api.nvim_buf_is_valid(bufnr), "buffer should be closed on 'y'")
end

-- 3. Modified buffer + "n" response: stays open.
do
  local bufnr = start_template()
  vim.bo[bufnr].modified = true

  local original = vim.ui.input
  vim.ui.input = function(_o, cb)
    cb("n")
  end

  capture.cancel(bufnr)

  vim.ui.input = original
  assert(vim.api.nvim_buf_is_valid(bufnr), "buffer should remain open on 'n'")

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 4. Modified buffer + nil (Esc): stays open.
do
  local bufnr = start_template()
  vim.bo[bufnr].modified = true

  local original = vim.ui.input
  vim.ui.input = function(_o, cb)
    cb(nil)
  end

  capture.cancel(bufnr)

  vim.ui.input = original
  assert(vim.api.nvim_buf_is_valid(bufnr), "buffer should remain open on Esc")

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 5. cancel_insert defaults to nil — ESC keymap is NOT installed in capture buffer.
do
  local defaults = require("organ.defaults")
  assert(
    defaults.capture.keymaps.cancel_insert == nil,
    "cancel_insert should default to nil; got " .. tostring(defaults.capture.keymaps.cancel_insert)
  )

  -- Verify no ESC keymap is installed on a fresh capture buffer.
  local bufnr = start_template()
  local esc_seq = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  local found_esc = false
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
    if m.lhs == "<Esc>" or m.lhs == esc_seq then
      found_esc = true
      break
    end
  end
  assert(not found_esc, "ESC should NOT be mapped in capture buffer insert mode")

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 6. Asynchronous confirmation (callback via vim.schedule) still closes on "y".
do
  local bufnr = start_template()
  vim.bo[bufnr].modified = true
  local original = vim.ui.input
  vim.ui.input = function(_o, cb)
    vim.schedule(function()
      cb("y")
    end)
  end
  capture.cancel(bufnr)
  assert(vim.api.nvim_buf_is_valid(bufnr), "buffer stays open until the answer arrives")
  vim.wait(500, function()
    return not vim.api.nvim_buf_is_valid(bufnr)
  end)
  vim.ui.input = original
  assert(not vim.api.nvim_buf_is_valid(bufnr), "buffer should be closed after async 'y'")
end

vim.fn.delete(tmp, "rf")
io.write("capture cancel ok\n")
os.exit(0)
