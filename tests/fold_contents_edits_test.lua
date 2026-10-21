-- The CONTENTS view through edits: a revealed heading stays revealed when
-- its headline changes, a line typed under a heading stays visible, and a
-- reveal belongs to the window that made it.
-- Run via: nvim --headless -l tests/fold_contents_edits_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("organ").setup({
  org_dir = dir,
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
vim.cmd("filetype plugin indent on")

local contents = require("organ.fold.contents")
local fold = require("organ.fold")

local failures = 0
local function check(label, ok, detail)
  if not ok then
    failures = failures + 1
    io.write("FAIL " .. label .. (detail and (": " .. tostring(detail)) or "") .. "\n")
  end
end

local function settle()
  for _ = 1, 4 do
    vim.wait(10)
  end
  require("organ.fold.marks").on_safe_state()
  contents.refresh(vim.api.nvim_get_current_buf())
end

local function line_of(text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l == text then
      return i
    end
  end
  error("no line " .. text)
end

local n = 0
local function open_contents()
  n = n + 1
  local f = dir .. "/c" .. n .. ".org"
  vim.fn.writefile({ "* A", "body a", "* C", "body c", "* E", "body e" }, f)
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit " .. vim.fn.fnameescape(f))
  settle()
  fold.apply_global_state("content", vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
  settle()
end

-- A TODO change on a revealed heading keeps it revealed.
open_contents()
contents.toggle_heading(0, line_of("* C"))
settle()
check("C is revealed", not contents.heading_concealed(0, line_of("* C")))
require("organ.todo").cycle(0, line_of("* C"))
settle()
check("TODO change keeps C revealed", not contents.heading_concealed(0, line_of("* TODO C")))
check("A stays concealed", contents.heading_concealed(0, line_of("* A")))

-- A line typed under a heading stays visible: the heading is revealed.
open_contents()
vim.api.nvim_win_set_cursor(0, { line_of("* A"), 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("otyped<Esc>", true, false, true), "xt", false)
settle()
check("typing under A reveals it", not contents.heading_concealed(0, line_of("* A")))
check("C stays concealed", contents.heading_concealed(0, line_of("* C")))

-- A reveal in one CONTENTS window does not show in another.
open_contents()
local w1 = vim.api.nvim_get_current_win()
vim.cmd("split")
local w2 = vim.api.nvim_get_current_win()
fold.apply_global_state("content", w2, vim.api.nvim_get_current_buf())
settle()
vim.api.nvim_set_current_win(w1)
contents.toggle_heading(0, line_of("* C"))
settle()
check("revealed in the window that revealed it", not contents.heading_concealed(0, line_of("* C")))
vim.api.nvim_set_current_win(w2)
settle()
check("still concealed in the other window", contents.heading_concealed(0, line_of("* C")))
vim.cmd("only")

vim.fn.delete(dir, "rf")
if failures > 0 then
  os.exit(1)
end
io.write("fold contents edits ok\n")
