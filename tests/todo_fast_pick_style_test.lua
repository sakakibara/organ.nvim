-- `todo.fast_pick_style` controls the prompt UI for the fast-pick
-- TODO menu (the `:Org todo` keymap).  Default `"popup"` opens a
-- modal floating window that blocks on getcharstr until the user
-- types a key; `"echo"` uses nvim_echo + getcharstr (which can be
-- overdrawn by async UI plugins, the original bug).
--
-- Both styles end at the same getcharstr call, so we can drive
-- them with the same stub.  This test asserts:
--   1. default style is "popup" and a floating window is opened
--      during the wait (verified by checking nvim_list_wins from
--      inside the stubbed getcharstr)
--   2. "echo" style opens NO popup
--   3. both styles dispatch on the typed key correctly
--
-- Run via: nvim --headless -l tests/todo_fast_pick_style_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function fresh_setup(style)
  require("organ").config = require("organ.defaults")
  local cfg = {
    org_dir = "/tmp",
    notify = false,
    scan_on_startup = false,
    watcher = { enabled = false },
    todo = {
      sequence = { "TODO(t)", "WAIT(w)", "|", "DONE(d)" },
    },
  }
  if style ~= nil then
    cfg.todo.fast_pick_style = style
  end
  require("organ").setup(cfg)
end

-- Drive fast_select with a stubbed getcharstr that records the
-- floating-window count at the moment of the keypress.  Returns
-- (headline_after, win_count_during_wait).
local function pick_with(b, line, code, expect_popup_during_wait)
  local todo = require("organ.todo")
  local saved_g = vim.fn.getcharstr
  local saved_i = vim.fn.input
  local wins_during = -1
  vim.fn.getcharstr = function()
    wins_during = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative == "editor" or cfg.relative == "win" then
        wins_during = wins_during + 1
      end
    end
    return code
  end
  vim.fn.input = function()
    return ""
  end
  todo._fast_select(b, line)
  vim.fn.getcharstr = saved_g
  vim.fn.input = saved_i
  return vim.api.nvim_buf_get_lines(b, line - 1, line, false)[1], wins_during
end

-- ─── 1. Default style is "popup" -- a floating window IS up during wait ─────
do
  fresh_setup(nil) -- no override = default
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Pick" })
  vim.bo[b].buftype = "nofile"

  local after, wins = pick_with(b, 1, "d")
  check(
    "default style: a floating window is up during getcharstr",
    wins >= 1,
    "got " .. wins .. " floats"
  )
  check("default style: 'd' -> DONE", after == "* DONE Pick", "got " .. tostring(after))

  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── 2. "echo" style: NO popup, dispatch still works ───────────────────────
do
  fresh_setup("echo")
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Pick" })
  vim.bo[b].buftype = "nofile"

  local after, wins = pick_with(b, 1, "w")
  check("echo style: no floating window during wait", wins == 0, "got " .. wins .. " floats")
  check("echo style: 'w' -> WAIT", after == "* WAIT Pick", "got " .. tostring(after))

  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── 3. Both styles: cancel (<Esc>) is a no-op ──────────────────────────────
do
  fresh_setup("popup")
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Cancel" })
  vim.bo[b].buftype = "nofile"
  local after = pick_with(b, 1, "\27")
  check("popup style: <Esc> cancels (headline unchanged)", after == "* TODO Cancel")
  vim.api.nvim_buf_delete(b, { force = true })
end
do
  fresh_setup("echo")
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Cancel" })
  vim.bo[b].buftype = "nofile"
  local after = pick_with(b, 1, "\27")
  check("echo style: <Esc> cancels (headline unchanged)", after == "* TODO Cancel")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── 4. <Space> clears state in both styles ─────────────────────────────────
do
  fresh_setup("popup")
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Clear" })
  vim.bo[b].buftype = "nofile"
  local after = pick_with(b, 1, " ")
  check("popup style: <Space> clears state", after == "* Clear")
  vim.api.nvim_buf_delete(b, { force = true })
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("todo_fast_pick_style_test: PASS")
