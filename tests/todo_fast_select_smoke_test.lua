-- Smoke test: fast-selection UI applies the right state on the
-- single-char prompt.  Stubs vim.fn.getcharstr() so we don't need
-- a real terminal.
-- Run via: nvim --headless -l tests/todo_fast_select_smoke_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = {
    sequence = { "TODO(t)", "WAIT(w@)", "|", "DONE(d!)", "CANCELED(c)" },
  },
})

local todo = require("organ.todo")

-- Helper: stub vim.fn.getcharstr to return `code`, run fast_select,
-- restore the original.  Returns the line content after.
local function with_input(bufnr, line, code)
  local saved = vim.fn.getcharstr
  vim.fn.getcharstr = function()
    return code
  end
  todo._fast_select(bufnr, line)
  vim.fn.getcharstr = saved
  return vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
end

-- ---------------------------------------------------------------------------
-- Press the matching key -> headline state changes.
-- ---------------------------------------------------------------------------
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Pick a state" })
vim.bo[b].buftype = "nofile"

check("press 'd' -> headline becomes DONE", with_input(b, 1, "d") == "* DONE Pick a state")

check("press 'w' -> headline becomes WAIT", with_input(b, 1, "w") == "* WAIT Pick a state")

check("press 'c' -> headline becomes CANCELED", with_input(b, 1, "c") == "* CANCELED Pick a state")

check("press 't' -> headline becomes TODO", with_input(b, 1, "t") == "* TODO Pick a state")

-- ---------------------------------------------------------------------------
-- <Space> clears the state.
-- ---------------------------------------------------------------------------
check("press '<Space>' -> headline state cleared", with_input(b, 1, " ") == "* Pick a state")

-- ---------------------------------------------------------------------------
-- <Esc> cancels (no change).
-- ---------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Cancel test" })
check("press '<Esc>' -> headline unchanged", with_input(b, 1, "\27") == "* TODO Cancel test")

-- ---------------------------------------------------------------------------
-- Unknown key: error notify, headline unchanged.
-- ---------------------------------------------------------------------------
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO Unknown key" })
check("press 'q' (unknown) -> headline unchanged", with_input(b, 1, "q") == "* TODO Unknown key")

vim.api.nvim_buf_delete(b, { force = true })

-- ---------------------------------------------------------------------------
-- No-annotation fallback: when sequence has no `(KEY)` suffixes,
-- fast_select uses vim.ui.select instead of erroring.
-- ---------------------------------------------------------------------------
require("organ").config.todo.sequence = { "TODO", "|", "DONE" }

local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "* TODO Plain task" })
vim.bo[b2].buftype = "nofile"

local select_called = false
local saved_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  select_called = true
  -- Pick "DONE" from the list.
  for _, item in ipairs(items) do
    if item == "DONE" then
      on_choice("DONE")
      return
    end
  end
end

todo._fast_select(b2, 1)
vim.ui.select = saved_select

check("no-annotation: vim.ui.select fallback fires", select_called)
check(
  "no-annotation: chosen state applied",
  vim.api.nvim_buf_get_lines(b2, 0, 1, false)[1] == "* DONE Plain task"
)

vim.api.nvim_buf_delete(b2, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("todo_fast_select_smoke_test: PASS")
