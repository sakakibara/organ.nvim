-- find.actions_links.follow and .jump_to_source dispatch correctly per
-- target_type, with source-line cursor positioning for jump_to_source.
-- Run via: nvim --headless -l tests/find_link_actions_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fh = assert(io.open(org_dir .. "/x.org", "w"))
fh:write([=[* Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:
  Body line.

* Beta
  :PROPERTIES:
  :ID:       beta-id
  :END:
  See [[id:alpha-id][Alpha]].
]=])
fh:close()

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  mtime_skip = false,
  incremental = false,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

local find = require("organ.find")
assert(type(find.actions_links) == "table", "actions_links table missing")
assert(type(find.actions_links.follow) == "function", "follow missing")
assert(type(find.actions_links.jump_to_source) == "function", "jump_to_source missing")

find.pick({
  source = "links",
  filter = {},
  default_action = "follow",
  actions = {
    follow = find.actions_links.follow,
    jump_to_source = find.actions_links.jump_to_source,
  },
})

local stub = require("organ.find.backend")._test_stub
local items = stub.last.items
assert(items and #items > 0, "expected items; got " .. tostring(#(items or {})))

-- Find an id-typed item that resolves to a target headline.
local id_item
for _, it in ipairs(items) do
  if it.target_type == "id" and it.target_headline then
    id_item = it
    break
  end
end
assert(id_item, "expected at least one resolvable id-typed item")

-- follow → opens the target headline's file at line_start + 1.
find.actions_links.follow(id_item)
local cur_path = vim.api.nvim_buf_get_name(0)
assert(cur_path:match("/x%.org$"), "follow id should open source file: " .. cur_path)
local cur_line = vim.api.nvim_win_get_cursor(0)[1]
assert(
  cur_line == id_item.target_headline.line_start + 1,
  "expected cursor at " .. (id_item.target_headline.line_start + 1) .. ", got " .. cur_line
)

-- jump_to_source → opens the source file at the link's line.
find.actions_links.jump_to_source(id_item)
cur_path = vim.api.nvim_buf_get_name(0)
assert(
  cur_path == id_item.source.file_path,
  "jump_to_source should open source.file_path; got " .. cur_path
)
cur_line = vim.api.nvim_win_get_cursor(0)[1]
assert(cur_line == id_item.line, "expected cursor at line " .. id_item.line .. ", got " .. cur_line)

-- follow on an unresolvable id → notify-error path; we just verify it doesn't raise.
local fake_item = {
  target_type = "id",
  target = "does-not-exist",
  source = { file_path = id_item.source.file_path },
  line = 1,
}
local ok = pcall(find.actions_links.follow, fake_item)
assert(ok, "follow on unresolvable id should not raise")

-- follow on a file-typed item → :edit's the file path.
local file_item = {
  target_type = "file",
  target = org_dir .. "/x.org",
  source = id_item.source,
  line = 1,
}
find.actions_links.follow(file_item)
assert(vim.api.nvim_buf_get_name(0):match("/x%.org$"), "follow file should :edit the path")

-- follow on a file-typed item with anchor → opens file at the anchored line.
local target_path = org_dir .. "/anchored.org"
do
  local f = assert(io.open(target_path, "w"))
  f:write([=[* Top
  body
* Anchored Heading
  more
]=])
  f:close()
end
require("organ").scan_blocking(org_dir, 5000)

local anchor_item = {
  target_type = "file",
  target = target_path .. "::*Anchored Heading",
  source = id_item.source,
  line = 1,
}
find.actions_links.follow(anchor_item)
do
  local got_path = vim.fn.resolve(vim.api.nvim_buf_get_name(0))
  local want_path = vim.fn.resolve(target_path)
  assert(
    got_path == want_path,
    "follow file-with-anchor should :edit the path; got " .. got_path .. ", want " .. want_path
  )
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, cur - 1, cur, false)[1]
  assert(
    text == "* Anchored Heading",
    "expected cursor on '* Anchored Heading'; got line " .. cur .. " = " .. tostring(text)
  )
end

-- follow on a property-value-typed item → jumps to the headline owning the
-- matching :KEY: property value.
do
  -- Append a headline with a unique ROAM_REFS to the existing fixture.
  local f = assert(io.open(org_dir .. "/x.org", "a"))
  f:write([=[

* RefHolder
  :PROPERTIES:
  :ROAM_REFS: https://unique.example.com
  :END:
]=])
  f:close()
  require("organ").scan_blocking(org_dir, 5000)

  local prop_item = {
    target_type = "ROAM_REFS",
    target = "https://unique.example.com",
    source = id_item.source,
    line = 1,
  }
  vim.cmd("enew")
  find.actions_links.follow(prop_item)

  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
  assert(
    text == "* RefHolder",
    "expected cursor on '* RefHolder'; got line " .. cur_line .. " = " .. tostring(text)
  )
end

-- follow on an http-typed item → vim.ui.open mocked.
local opened
local original_ui_open = vim.ui.open
vim.ui.open = function(url)
  opened = url
end
local http_item = {
  target_type = "https",
  target = "https://example.com",
  source = id_item.source,
  line = 1,
}
find.actions_links.follow(http_item)
vim.ui.open = original_ui_open
assert(
  opened == "https://example.com",
  "follow https should call vim.ui.open with the URL; got " .. tostring(opened)
)

vim.fn.delete(tmp, "rf")
io.write("find link actions ok\n")
os.exit(0)
