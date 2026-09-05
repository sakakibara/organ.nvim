-- All 7 commands are registered. Each invokes find.pick with the expected
-- opts shape (filter, default_action, ctx capture for write-side commands).
-- Run via: nvim --headless -l tests/orgfind_commands_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([[* TODO Alpha
  :PROPERTIES:
  :ID:        alpha-id
  :ROAM_REFS: cite:knuth1968
  :END:

* DONE Beta
  :PROPERTIES:
  :ID:       beta-id
  :END:
]])
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

assert(vim.api.nvim_get_commands({}).Org, ":Org dispatcher not registered")
local cmd = require("organ").cmd
for _, path in ipairs({
  "find",
  "find tag",
  "find todo",
  "roam",
  "roam insert",
  "find ref",
  "refile",
}) do
  assert(cmd(path), "subcommand `" .. path .. "` not registered on :Org")
end

local stub = require("organ.find.backend")._test_stub

-- :Org find — filter empty, default_action jump
vim.cmd("Org find")
assert(stub.last.opts.default_action == "jump")
assert(#stub.last.items == 2, "OrgFind expected 2 items, got " .. #stub.last.items)

-- :Org find todo — default include = {TODO, NEXT}
vim.cmd("Org find todo")
assert(#stub.last.items == 1, "default OrgFindTodo expected 1 (Alpha), got " .. #stub.last.items)
assert(stub.last.items[1].title == "Alpha")

-- :Org find todo DONE — explicit
vim.cmd("Org find todo DONE")
assert(#stub.last.items == 1)
assert(stub.last.items[1].title == "Beta")

-- :Org roam — has_id, both Alpha & Beta have IDs
vim.cmd("Org roam")
assert(#stub.last.items == 2)
assert(type(stub.last.opts.create) == "function", "OrgRoam should pass create callback")

-- :Org find ref — has_property = ROAM_REFS, only Alpha
vim.cmd("Org find ref")
assert(#stub.last.items == 1)
assert(stub.last.items[1].title == "Alpha")

-- :Org roam insert — default_action insert_link, ctx captured
local sb = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(sb, 0, -1, false, { "see foo" })
vim.api.nvim_set_current_buf(sb)
vim.api.nvim_win_set_cursor(0, { 1, 4 })
vim.cmd("Org roam insert")
assert(stub.last.opts.default_action == "insert_link")
-- ctx isn't part of opts in the public schema; the action wraps it, so the
-- only honest check is to run the very action the command built and see the
-- link land in the source buffer.
assert(
  type(stub.last.opts.actions.insert_link) == "function",
  "OrgRoamInsert should install an insert_link action via ctx"
)
do
  local alpha
  for _, it in ipairs(stub.last.items) do
    if it.title == "Alpha" then
      alpha = it
    end
  end
  assert(alpha, "expected an Alpha node among the roam-insert items")
  stub.last.opts.actions.insert_link(alpha)
  local line = vim.api.nvim_buf_get_lines(sb, 0, 1, false)[1]
  assert(
    line == "see [[id:alpha-id][foo]]",
    "OrgRoamInsert should replace the cword with the link, got: " .. tostring(line)
  )
end

-- :Org refile — default_action refile_here
vim.api.nvim_buf_set_lines(sb, 0, -1, false, { "* X", "  body" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("Org refile")
assert(stub.last.opts.default_action == "refile_here")
assert(type(stub.last.opts.actions.refile_here) == "function")

vim.fn.delete(tmp, "rf")
io.write("orgfind commands ok\n")
os.exit(0)
