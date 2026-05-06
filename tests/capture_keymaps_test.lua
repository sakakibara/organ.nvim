-- Tests for Vim-native capture keymap defaults: ZZ finalises, q cancels, <CR> finalises.
-- Phase 1 of UX audit (2026-04-26).
-- Run via: nvim --headless -l tests/capture_keymaps_test.lua

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

local defaults = require("organ.defaults")
local capture = require("organ.capture")

-- Helper: start a capture and return the buffer number.
local function start_template()
  capture.start({
    name = "Test",
    target = { kind = "file", path = target_path },
    body = "* TODO test",
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

-- 1. Default keymaps use Vim-native values.
do
  local km = defaults.capture.keymaps
  assert(km.finalise == "ZZ", "default finalise should be ZZ; got " .. tostring(km.finalise))
  assert(
    km.finalise_alt == "<CR>",
    "default finalise_alt should be <CR>; got " .. tostring(km.finalise_alt)
  )
  assert(km.cancel == "ZQ", "default cancel should be ZQ; got " .. tostring(km.cancel))
  assert(
    km.cancel_normal == "q",
    "default cancel_normal should be q; got " .. tostring(km.cancel_normal)
  )
end

-- 2. ZZ (finalise) is mapped in the capture buffer (normal mode).
do
  local bufnr = start_template()
  local found_zz_n = false
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == "ZZ" then
      found_zz_n = true
      break
    end
  end
  assert(found_zz_n, "ZZ should be mapped in normal mode on capture buffer")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 3. ZZ (finalise) is mapped in insert mode too.
do
  local bufnr = start_template()
  local found_zz_i = false
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
    if m.lhs == "ZZ" then
      found_zz_i = true
      break
    end
  end
  assert(found_zz_i, "ZZ should be mapped in insert mode on capture buffer")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 4. <CR> (finalise_alt) is mapped in normal mode only.
do
  local bufnr = start_template()
  local found_cr_n = false
  local found_cr_i = false
  local cr = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == "<CR>" or m.lhs == cr then
      found_cr_n = true
    end
  end
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
    if m.lhs == "<CR>" or m.lhs == cr then
      found_cr_i = true
    end
  end
  assert(found_cr_n, "<CR> should be mapped in normal mode on capture buffer")
  assert(not found_cr_i, "<CR> should NOT be mapped in insert mode on capture buffer")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 5. q (cancel_normal) is mapped in normal mode.
do
  local bufnr = start_template()
  local found_q_n = false
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == "q" then
      found_q_n = true
      break
    end
  end
  assert(found_q_n, "q should be mapped in normal mode on capture buffer")
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

-- 6. ZZ in normal mode actually finalises (closes buffer + writes file).
do
  vim.fn.writefile({ "* Existing" }, target_path)
  local bufnr = start_template()
  -- Simulate normal-mode ZZ by calling the bound callback directly (since
  -- nvim_feedkeys would require event loop processing outside headless).
  local km_list = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local zz_cb
  for _, m in ipairs(km_list) do
    if m.lhs == "ZZ" then
      zz_cb = m.callback
      break
    end
  end
  assert(zz_cb, "ZZ callback not found on capture buffer")
  zz_cb()
  assert(not vim.api.nvim_buf_is_valid(bufnr), "buffer should be closed after ZZ finalise")
  local result = vim.fn.readfile(target_path)
  local found = false
  for _, l in ipairs(result) do
    if l:find("TODO test") then
      found = true
      break
    end
  end
  assert(found, "captured text should appear in file after ZZ; got: " .. vim.inspect(result))
end

-- 7. q in normal mode cancels unmodified buffer (no prompt, closes immediately).
do
  local bufnr = start_template()
  vim.bo[bufnr].modified = false
  local km_list = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local q_cb
  for _, m in ipairs(km_list) do
    if m.lhs == "q" then
      q_cb = m.callback
      break
    end
  end
  assert(q_cb, "q callback not found on capture buffer")
  local prompted = false
  local original_input = vim.ui.input
  vim.ui.input = function()
    prompted = true
  end
  q_cb()
  vim.ui.input = original_input
  assert(not prompted, "q on unmodified buffer should not prompt")
  assert(not vim.api.nvim_buf_is_valid(bufnr), "buffer should be closed after q cancel")
end

vim.fn.delete(tmp, "rf")
io.write("capture keymaps ok\n")
os.exit(0)
