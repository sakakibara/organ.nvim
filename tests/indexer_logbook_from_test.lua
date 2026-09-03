-- extract() reads LOGBOOK state lines in both forms Emacs writes:
-- `from "TODO"` and, for an entry entered from no state, a bare `from`
-- followed only by the timestamp.
-- Run via: nvim --headless -l tests/indexer_logbook_from_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  db_path = tmp .. "/k.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local extract = require("organ.indexer.extract")
local parser_path = require("organ.defaults").parser_path

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local src = table.concat({
  "* DONE Task",
  "  :LOGBOOK:",
  '  - State "DONE"       from "TODO"       [2026-05-02 Sat 10:00]',
  '  - State "TODO"       from              [2026-05-01 Fri 09:00]',
  '  - State "NEXT"       from "(none)"       [2026-04-30 Thu 09:00]',
  "  :END:",
  "",
}, "\n")

local h = extract.extract(src, tmp .. "/x.org", parser_path)[1]
local changes = h.state_changes or {}
check("three state changes indexed", #changes == 3, vim.inspect(changes))
local by_to = {}
for _, c in ipairs(changes) do
  by_to[c.to_state] = c
end
check("quoted from state kept", by_to.DONE and by_to.DONE.from_state == "TODO", vim.inspect(by_to))
check(
  "bare from reads as no previous state",
  by_to.TODO and by_to.TODO.from_state == "",
  vim.inspect(by_to)
)
check(
  "legacy quoted (none) reads as no previous state",
  by_to.NEXT and by_to.NEXT.from_state == "",
  vim.inspect(by_to)
)
check(
  "DONE completion date indexed",
  vim.deep_equal(h.habit_completions, { "2026-05-02" }),
  vim.inspect(h.habit_completions)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("indexer_logbook_from_test: PASS")
os.exit(0)
