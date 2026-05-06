-- find.pick({...}) builds items via query.headlines(filter), formats their
-- display, and invokes the configured backend with a fully-populated opts.
-- Run via: nvim --headless -l tests/find_pick_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([[* TODO Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:

* DONE Beta
  :PROPERTIES:
  :ID:       beta-id
  :END:
]])
fh:close()

-- Capture backend invocations.
local captured = {}
require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = {
    backend = function(items, opts)
      captured = { items = items, opts = opts }
    end,
    columns = { "todo", "title" },
    match_fields = { "title" },
    keymaps = { jump = "<CR>", split = "<C-s>" },
  },
})
require("organ").scan_blocking(org_dir, 5000)

local find = require("organ.find")

find.pick({
  source = "headlines",
  filter = { todo = { include = { "TODO" } } },
  default_action = "jump",
})

-- Items: only Alpha (TODO), with todo + title display.
assert(captured.items, "backend was not invoked")
assert(#captured.items == 1, "expected 1 item, got " .. #captured.items)
assert(captured.items[1].title == "Alpha")
assert(captured.items[1].id == "alpha-id")
assert(captured.items[1].display:find("Alpha", 1, true))
assert(captured.items[1].display:find("TODO", 1, true))
assert(captured.items[1].match_fields[1] == "title")

-- Opts: standard actions present + caller's default_action.
assert(captured.opts.default_action == "jump")
assert(type(captured.opts.actions.jump) == "function")
assert(type(captured.opts.actions.split) == "function")
assert(type(captured.opts.actions.vsplit) == "function")
assert(type(captured.opts.actions.tab) == "function")
assert(type(captured.opts.actions.backlinks) == "function")
assert(captured.opts.keymaps.jump == "<CR>")
assert(captured.opts.keymaps.split == "<C-s>")

vim.fn.delete(tmp, "rf")
io.write("find pick ok\n")
os.exit(0)
