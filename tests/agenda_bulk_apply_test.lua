-- Bulk actions resolve every marked row against an agenda snapshot, so
-- each edit invalidates the lines of the rows below it.  Driven by real
-- keypresses (`<Space>` to mark, `gB` for the action menu) so the whole
-- bulk path is exercised.
-- Run via: nvim --headless -l tests/agenda_bulk_apply_test.lua

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

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local src = org_dir .. "/a.org"
vim.fn.writefile({ "* TODO alpha", "* TODO beta", "* TODO gamma" }, src)

require("organ").setup({
  db_path = tmp .. "/bulk.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = "time" },
})
require("organ").scan_blocking(org_dir, 5000)

local agenda = require("organ.agenda")
local bufnr = agenda.open({
  blocks = { { label = "TODOs", kind = "todo", todo = { exclude = { "DONE" } } } },
}, "todos")
vim.api.nvim_win_set_buf(0, bufnr)

local function row_line(title)
  for l = 1, vim.api.nvim_buf_line_count(bufnr) do
    if (vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""):match(title) then
      return l
    end
  end
end

-- Mark alpha and gamma; beta stays unmarked between them, so a stale
-- line number lands on beta.
for _, title in ipairs({ "alpha", "gamma" }) do
  local l = row_line(title)
  check("agenda lists " .. title, l ~= nil)
  if l then
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    vim.api.nvim_feedkeys(" ", "x", false)
  end
end

local orig_select = vim.ui.select
local answers = { "Set TODO state", "DONE" }
vim.ui.select = function(items, _, on_choice)
  local want = table.remove(answers, 1)
  for i, it in ipairs(items) do
    if it == want then
      return on_choice(it, i)
    end
  end
  return on_choice(nil, nil)
end
vim.api.nvim_feedkeys("gB", "x", false)
vim.ui.select = orig_select

local out = vim.api.nvim_buf_get_lines(vim.fn.bufadd(src), 0, -1, false)
local function state_of(title)
  for _, l in ipairs(out) do
    local kw = l:match("^%*+%s+(%u+)%s+" .. title .. "$")
    if kw then
      return kw
    end
    if l:match("^%*+%s+" .. title .. "$") then
      return "(none)"
    end
  end
end

check("bulk DONE applied to the first marked row", state_of("alpha") == "DONE", vim.inspect(out))
check("bulk DONE applied to the second marked row", state_of("gamma") == "DONE", vim.inspect(out))
check("bulk DONE left the unmarked row alone", state_of("beta") == "TODO", vim.inspect(out))

vim.fn.delete(tmp, "rf")
if fails > 0 then
  error(fails .. " checks failed")
end
print("\nAll checks passed.")
