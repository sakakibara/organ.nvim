-- :Org edit_todo_states / :Org edit_tags edit the buffer's `#+TODO:` /
-- `#+TAGS:` directives via vim.ui.input.  When the directive is
-- absent, it's INSERTED at the top of the buffer.  When present,
-- the existing line is REPLACED in place.  After accept, the per-
-- buffer todo keyword highlights re-register so newly-added
-- keywords get the active/done coloring.
--
-- Run via: nvim --headless -l tests/edit_todo_states_test.lua

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
})

local directive = require("organ.directive")

-- Override vim.ui.input to drive the prompt programmatically.
local captured_prompt
local input_value
vim.ui.input = function(opts, on_choice)
  captured_prompt = opts and opts.prompt
  on_choice(input_value)
end

-- ---------------------------------------------------------------------------
-- (a) Buffer with no #+TODO line: the command INSERTS one near top.
-- ---------------------------------------------------------------------------
local b1 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b1, 0, -1, false, {
  "#+TITLE: My doc",
  "",
  "* TODO First task",
})
vim.api.nvim_set_current_buf(b1)

input_value = "TODO NEXT WAIT | DONE"
directive.commands.edit_todo_states.fn()

local lines1 = vim.api.nvim_buf_get_lines(b1, 0, -1, false)
local found_todo = false
for _, l in ipairs(lines1) do
  if l == "#+TODO: TODO NEXT WAIT | DONE" then
    found_todo = true
  end
end
check("insert: #+TODO directive added when absent", found_todo, vim.inspect(lines1))
check("insert: prompt was shown", captured_prompt == "TODO states: ")

-- ---------------------------------------------------------------------------
-- (b) Buffer with existing #+TODO: replaces in place.
-- ---------------------------------------------------------------------------
local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, {
  "#+TITLE: Doc",
  "#+TODO: TODO | DONE",
  "",
  "* TODO foo",
})
vim.api.nvim_set_current_buf(b2)

input_value = "PROJ NEXT | CANCEL DONE"
directive.commands.edit_todo_states.fn()

local lines2 = vim.api.nvim_buf_get_lines(b2, 0, -1, false)
check(
  "replace: existing #+TODO line is rewritten in place",
  lines2[2] == "#+TODO: PROJ NEXT | CANCEL DONE",
  vim.inspect(lines2)
)
check(
  "replace: surrounding lines untouched",
  lines2[1] == "#+TITLE: Doc" and lines2[3] == "" and lines2[4] == "* TODO foo"
)

-- ---------------------------------------------------------------------------
-- (c) :Org edit_tags — same flow.
-- ---------------------------------------------------------------------------
local b3 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b3, 0, -1, false, { "* TODO foo" })
vim.api.nvim_set_current_buf(b3)

input_value = "{ work(w) home(h) }"
directive.commands.edit_tags.fn()
local lines3 = vim.api.nvim_buf_get_lines(b3, 0, -1, false)
local got_tags = false
for _, l in ipairs(lines3) do
  if l == "#+TAGS: { work(w) home(h) }" then
    got_tags = true
  end
end
check("OrgEditTags: #+TAGS directive added when absent", got_tags, vim.inspect(lines3))

-- ---------------------------------------------------------------------------
-- (d) Cancellation (nil from input) is a no-op.
-- ---------------------------------------------------------------------------
local b4 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b4, 0, -1, false, { "#+TITLE: x", "* TODO y" })
vim.api.nvim_set_current_buf(b4)
input_value = nil
directive.commands.edit_todo_states.fn()
local lines4 = vim.api.nvim_buf_get_lines(b4, 0, -1, false)
check("cancel: empty/nil input is no-op", #lines4 == 2 and lines4[1] == "#+TITLE: x")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("edit_todo_states_test: PASS")
