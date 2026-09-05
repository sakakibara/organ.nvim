-- The agenda registers a window-scoped WinResized autocmd that Neovim
-- cannot remove with the buffer, so wiping the agenda buffer must tear
-- its augroup down.  Counting autocmds across open-and-wipe cycles
-- catches any future registration that outlives its buffer.
-- Run via: nvim --headless -l tests/agenda_autocmd_leak_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
vim.fn.writefile({ "* TODO thing", "  SCHEDULED: <2026-04-23 Thu>" }, org_dir .. "/a.org")

require("organ").setup({
  db_path = tmp .. "/a.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function cycle()
  local bufnr = agenda.open({ from = "2026-04-01", to = "2026-06-01", now = "2026-04-23" })
  assert(type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr), "agenda did not open")
  vim.cmd("enew")
  vim.cmd("bwipeout! " .. bufnr)
end

-- One warm-up cycle so lazily-required modules have registered whatever
-- global autocmds they own; the measured cycles then only differ by
-- per-buffer registrations.
cycle()
local before = #vim.api.nvim_get_autocmds({})
for _ = 1, 3 do
  cycle()
end
local after = #vim.api.nvim_get_autocmds({})

check(
  "no autocmds survive an agenda open-and-wipe cycle",
  after == before,
  ("before=%d after=%d"):format(before, after)
)

local leftover = 0
for _, c in ipairs(vim.api.nvim_get_autocmds({})) do
  if c.group_name and c.group_name:match("^organ_agenda_resize_") then
    leftover = leftover + 1
  end
end
check("no organ_agenda_resize_<bufnr> autocmds left", leftover == 0, "got " .. leftover)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
io.write("agenda_autocmd_leak ok\n")
os.exit(0)
