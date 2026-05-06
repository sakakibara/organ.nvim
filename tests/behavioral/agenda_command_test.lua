-- Behavioral test: `:Org agenda week` produces a populated agenda
-- buffer.  Same destination as the `<Leader>oa` keymap test, but
-- this time we drive via the user command — bypassing the keymap
-- and the dispatcher menu.  Exercises the cmdline → dispatcher
-- subcommand → agenda render chain.
--
-- Run via: nvim --headless -l tests/behavioral/agenda_command_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.system({ "cp", root .. "/tests/fixtures/parity/tasks.org", org_dir .. "/tasks.org" })

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAIT", "PROJ", "|", "DONE", "CANCELLED" } },
})
require("organ").scan_blocking(org_dir, 5000)

-- The user command path — what gets typed into the cmdline.
local pre_bufs = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  pre_bufs[b] = true
end

vim.cmd("Org agenda week")
vim.wait(500, function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not pre_bufs[b] and vim.bo[b].filetype == "organ-agenda" then
      return vim.api.nvim_buf_line_count(b) > 1
    end
  end
  return false
end)

local agenda_buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if not pre_bufs[b] and vim.bo[b].filetype == "organ-agenda" then
    agenda_buf = b
    break
  end
end
check("`:Org agenda week` produced an `organ-agenda` buffer", agenda_buf ~= nil)

if agenda_buf then
  local lines = vim.api.nvim_buf_get_lines(agenda_buf, 0, -1, false)
  check("agenda buffer is non-empty", #lines > 1, ("only %d lines"):format(#lines))
  check(
    "first line is the agenda view header",
    lines[1] and lines[1]:match("^Week%-agenda %(W%d%d") ~= nil,
    ("got: %q"):format(tostring(lines[1]))
  )
  local found_dentist = false
  for _, l in ipairs(lines) do
    if l:find("Call dentist", 1, true) then
      found_dentist = true
      break
    end
  end
  check("fixture headline appears in rendered output", found_dentist)
end

-- Validate that an unknown subcommand surfaces a clear error rather
-- than silently doing nothing — the dispatcher contract.
local err_msg
local notify_orig = vim.notify
vim.notify = function(msg, level)
  if level == vim.log.levels.ERROR then
    err_msg = msg
  end
end
pcall(vim.cmd, "Org bogus_subcommand")
vim.notify = notify_orig
check(
  "unknown subcommand surfaces an error notification",
  err_msg and err_msg:find("Unknown :Org subcommand", 1, true) ~= nil,
  ("got: %q"):format(tostring(err_msg))
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("agenda_command_test: PASS")
