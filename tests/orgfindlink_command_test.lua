-- :Org find link registered; no-arg → all links; "id" / "http,https" → filtered;
-- captured opts have default_action="follow" and the two action factories.
-- Run via: nvim --headless -l tests/orgfindlink_command_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([=[* Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:
  See [[id:beta-id][Beta]] and [[https://example.com]].

* Beta
  :PROPERTIES:
  :ID:       beta-id
  :END:
  See [[id:alpha-id]].
]=])
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

assert(vim.api.nvim_get_commands({}).Org, ":Org not registered")
assert(
  require("organ").cmd("find link"),
  "subcommand `find_link` not registered in :Org dispatcher"
)

local stub = require("organ.find.backend")._test_stub

-- No arg → all 3 links surface.
vim.cmd("Org find link")
assert(
  stub.last.opts.default_action == "follow",
  "default_action should be 'follow'; got " .. tostring(stub.last.opts.default_action)
)
assert(type(stub.last.opts.actions.follow) == "function", "actions.follow missing")
assert(type(stub.last.opts.actions.jump_to_source) == "function", "actions.jump_to_source missing")
assert(#stub.last.items == 3, "no-arg expected 3 items, got " .. #stub.last.items)

-- Filter to id-typed only.
vim.cmd("Org find link id")
assert(#stub.last.items == 2, "id filter expected 2 items, got " .. #stub.last.items)
for _, it in ipairs(stub.last.items) do
  assert(it.target_type == "id", "expected id-only items; got " .. it.target_type)
end

-- Filter to https,http union (only one https in fixture).
vim.cmd("Org find link https,http")
assert(#stub.last.items == 1, "https,http expected 1 item, got " .. #stub.last.items)
assert(stub.last.items[1].target_type == "https")

vim.fn.delete(tmp, "rf")
io.write("orgfindlink command ok\n")
os.exit(0)
