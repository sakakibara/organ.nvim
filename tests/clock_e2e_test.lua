-- E2E: clock-in → state file populated → clock-out → CLOCK line
-- correctly closed → DB row inserted → report shows it.
-- Run via: nvim --headless -l tests/clock_e2e_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local data_dir = tmp .. "/data"
vim.fn.mkdir(data_dir, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(w)
  if w == "data" then
    return data_dir
  end
  return original_stdpath(w)
end

local fixture = vim.fn.resolve(org_dir .. "/x.org")
local f = assert(io.open(fixture, "w"))
f:write("* Project Alpha\n  :PROPERTIES:\n  :ID: alpha\n  :END:\n  body\n")
f:close()

local parser_path = original_stdpath("data") .. "/organ/parser/org.so"
if vim.fn.filereadable(parser_path) ~= 1 then
  io.write("(skipped: org tree-sitter parser not installed at " .. parser_path .. ")\n")
  io.write("clock_e2e_test: SKIP\n")
  vim.fn.stdpath = original_stdpath
  vim.fn.delete(tmp, "rf")
  os.exit(0)
end

require("organ").setup({
  db_path = tmp .. "/c.db",
  org_dir = org_dir,
  -- The mocked stdpath above would otherwise route the default
  -- parser_path into `tmp/data/...` where no parser lives.
  parser_path = parser_path,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  mtime_skip = false,
  hash_skip = false,
})
require("organ").scan_blocking(org_dir, 5000)

vim.cmd("edit " .. vim.fn.fnameescape(fixture))
local bufnr = vim.api.nvim_get_current_buf()
vim.bo.filetype = "org"

local clock = require("organ.clock")
local state_mod = require("organ.clock.state")

-- 1. clock-in writes CLOCK line + state file.
do
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on the headline
  clock.start({ bufnr = bufnr, line = 1 })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found
  for _, l in ipairs(lines) do
    if l:match("CLOCK:%s*%[%d+%-%d+%-%d+") and not l:match("%-%-%[") then
      found = l
      break
    end
  end
  assert(found, "active CLOCK line should be present; got\n" .. table.concat(lines, "\n"))

  local s = state_mod.load()
  assert(s, "state should exist after clock-in")
  assert(s.headline_id == "alpha", "state.headline_id: " .. tostring(s.headline_id))
end

-- 2. clock-out closes the CLOCK line + clears state.
do
  vim.cmd("write")
  clock.stop()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local closed
  for _, l in ipairs(lines) do
    if l:match("CLOCK:.*%-%-%[.*=>%s*%d+:%d+") then
      closed = l
      break
    end
  end
  assert(closed, "closed CLOCK line should be present; got\n" .. table.concat(lines, "\n"))
  assert(state_mod.load() == nil, "state should be cleared after clock-out")

  -- Save and reindex; the new closed entry should land in clock_entries.
  vim.cmd("write")
  require("organ").drain_blocking(2000)

  local h = require("organ").db_handle()
  local db = require("organ.db")
  local s = h:prepare("SELECT COUNT(*) FROM clock_entries WHERE headline_id = 'alpha'")
  assert(s:step() == db.SQLITE_ROW)
  local count = s:column_int(0)
  s:finalize()
  assert(count >= 1, "expected at least one clock_entries row for alpha; got " .. count)
end

-- 3. clock-out over a state file holding the state under `active`.
do
  clock.start({ bufnr = bufnr, line = 1 })
  local s = state_mod.load()
  assert(s and s.headline_id == "alpha", "state should exist after second clock-in")
  state_mod.save({ active = s })
  vim.cmd("write")
  local ok, err = pcall(clock.stop)
  assert(ok, "clock.stop over nested state raised: " .. tostring(err))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local open_count = 0
  for _, l in ipairs(lines) do
    if l:match("CLOCK:%s*%[%d+%-%d+%-%d+") and not l:match("%-%-%[") then
      open_count = open_count + 1
    end
  end
  assert(open_count == 0, "nested state: CLOCK line closed; got\n" .. table.concat(lines, "\n"))
  assert(state_mod.load() == nil, "nested state: cleared after clock-out")
end

-- 4. clock jump inside the clock's own file, with unsaved changes.  `:edit`
-- refuses that with E37 whatever 'hidden' is; Emacs `org-clock-goto` just
-- moves point.
do
  clock.start({ bufnr = bufnr, line = 1 })
  vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "  typed after clocking in" })
  assert(vim.bo[bufnr].modified, "buffer must be dirty for this to mean anything")
  local last = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(0, { last, 0 })
  local ok, err = pcall(clock.jump)
  assert(ok, "clock.jump inside the clocked file raised: " .. tostring(err))
  assert(vim.api.nvim_get_current_buf() == bufnr, "jump left the clocked buffer")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 1, "jump did not move to the headline")
  vim.cmd("write")
  clock.stop()
end

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmp, "rf")
io.write("clock e2e ok\n")
os.exit(0)
