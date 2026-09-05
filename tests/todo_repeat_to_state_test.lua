-- Where a repeating entry lands when marked done: `:REPEAT_TO_STATE:`,
-- `todo.repeat_to_state`, else the head of the entry's own sub-sequence.
-- Emacs oracle (org 9.7.11), `org-auto-repeat-maybe`:
--   #+TODO: TODO NEXT | DONE / `* TODO Rep` + `:REPEAT_TO_STATE: NEXT` -> `* NEXT Rep`
--   same sequence, `* NEXT Rep`, no property                           -> `* TODO Rep`
--   `org-todo-repeat-to-state` = t, `* NEXT Rep`                       -> `* NEXT Rep`
--   `org-todo-repeat-to-state` = "NEXT", `* TODO Rep`                  -> `* NEXT Rep`
--   `:REPEAT_TO_STATE: BOGUS` (not a keyword)                          -> `* TODO Rep`
--   property on the PARENT only (no inheritance)                       -> `* TODO Rep`
-- Run via: nvim --headless -l tests/todo_repeat_to_state_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = "time" },
})

local organ = require("organ")
local todo = require("organ.todo")
todo._now_for_test = function()
  return "2026-01-05"
end

local n = 0
local function run(body, target_line)
  n = n + 1
  local path = org_dir .. "/rts" .. n .. ".org"
  local fh = assert(io.open(path, "w"))
  fh:write(body)
  fh:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  assert(todo.set(b, target_line or 1, "DONE") == nil)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local SEQ = "#+TODO: TODO NEXT | DONE\n"

-- 1. `:REPEAT_TO_STATE: NEXT` wins.
do
  local l = run(
    SEQ
      .. "* TODO Rep\nSCHEDULED: <2026-01-01 Thu +1w>\n"
      .. ":PROPERTIES:\n:REPEAT_TO_STATE: NEXT\n:END:\n",
    2
  )
  assert(l[2] == "* NEXT Rep", "1: expected `* NEXT Rep`, got: " .. tostring(l[2]))
end

-- 2. No property: back to the HEAD of the sequence, not the state it had.
do
  local l = run(SEQ .. "* NEXT Rep\nSCHEDULED: <2026-01-01 Thu +1w>\n", 2)
  assert(l[2] == "* TODO Rep", "2: expected `* TODO Rep`, got: " .. tostring(l[2]))
end

-- 3. A value naming no configured keyword is discarded.
do
  local l = run(
    SEQ
      .. "* TODO Rep\nSCHEDULED: <2026-01-01 Thu +1w>\n"
      .. ":PROPERTIES:\n:REPEAT_TO_STATE: BOGUS\n:END:\n",
    2
  )
  assert(l[2] == "* TODO Rep", "3: expected `* TODO Rep`, got: " .. tostring(l[2]))
end

-- 4. The property is never inherited from a parent.
do
  local l = run(
    SEQ
      .. "* Parent\n:PROPERTIES:\n:REPEAT_TO_STATE: NEXT\n:END:\n"
      .. "** TODO Child\nSCHEDULED: <2026-01-01 Thu +1w>\n",
    6
  )
  assert(l[6] == "** TODO Child", "4: expected `** TODO Child`, got: " .. tostring(l[6]))
end

-- 5. `todo.repeat_to_state = "NEXT"`.
do
  organ.config.todo.repeat_to_state = "NEXT"
  local l = run(SEQ .. "* TODO Rep\nSCHEDULED: <2026-01-01 Thu +1w>\n", 2)
  organ.config.todo.repeat_to_state = nil
  assert(l[2] == "* NEXT Rep", "5: expected `* NEXT Rep`, got: " .. tostring(l[2]))
end

-- 6. `todo.repeat_to_state = true` keeps the state the entry had.
do
  organ.config.todo.repeat_to_state = true
  local l = run(SEQ .. "* NEXT Rep\nSCHEDULED: <2026-01-01 Thu +1w>\n", 2)
  organ.config.todo.repeat_to_state = nil
  assert(l[2] == "* NEXT Rep", "6: expected `* NEXT Rep`, got: " .. tostring(l[2]))
end

vim.fn.delete(tmp, "rf")
io.write("todo repeat_to_state ok\n")
os.exit(0)
