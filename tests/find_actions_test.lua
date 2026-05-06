-- Each action runs against a synthetic item: jump/split/vsplit/tab open the
-- right file at the right line; backlinks opens an organ-backlinks buffer;
-- insert_link with cword replaces it; insert_link without cword inserts at
-- cursor; insert_link inside a link/comment refuses (notify-warn, no-op).
-- Run via: nvim --headless -l tests/find_actions_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local target_file = org_dir .. "/x.org"
local fh = assert(io.open(target_file, "w"))
fh:write([[* Alpha
  :PROPERTIES:
  :ID:       alpha-id
  :END:
  Body line.
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

local find = require("organ.find")
find.pick({ source = "headlines", filter = {}, default_action = "jump" })
local opts = require("organ.find.backend")._test_stub.last.opts
local items = require("organ.find.backend")._test_stub.last.items
assert(#items == 1)
local item = items[1]

-- jump
opts.actions.jump(item)
assert(vim.api.nvim_buf_get_name(0):match("/x%.org$"), "jump didn't open x.org")
assert(vim.api.nvim_win_get_cursor(0)[1] == item.line_start + 1)

-- backlinks
opts.actions.backlinks(item)
assert(
  vim.bo[vim.api.nvim_get_current_buf()].filetype == "organ-backlinks",
  "backlinks should open organ-backlinks buffer"
)

-- insert_link with cword: edit a scratch buffer, place cursor on a word, run.
local sb = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(sb)
vim.api.nvim_buf_set_lines(sb, 0, -1, false, { "see foo for more" })
vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- on the 'f' of "foo" (0-based col 4)
local ctx = {
  bufnr = sb,
  win = vim.api.nvim_get_current_win(),
  cursor = { 1, 4 },
  cword = "foo",
  in_link = false,
  in_comment = false,
}
local insert_link = find.make_insert_link_action(ctx)
insert_link(item)
local line = vim.api.nvim_buf_get_lines(sb, 0, 1, false)[1]
assert(line:find("[[id:alpha-id][foo]]", 1, true), "expected link with cword, got: " .. line)

-- insert_link without cword: cursor at col 0 of an empty line.
local sb2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(sb2)
vim.api.nvim_buf_set_lines(sb2, 0, -1, false, { "" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local ctx2 = {
  bufnr = sb2,
  win = vim.api.nvim_get_current_win(),
  cursor = { 1, 0 },
  cword = "",
  in_link = false,
  in_comment = false,
}
find.make_insert_link_action(ctx2)(item)
local line2 = vim.api.nvim_buf_get_lines(sb2, 0, 1, false)[1]
assert(
  line2:find("[[id:alpha-id][Alpha]]", 1, true),
  "expected link with title fallback, got: " .. line2
)

-- insert_link inside a link: refuses.
local sb3 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(sb3)
vim.api.nvim_buf_set_lines(sb3, 0, -1, false, { "see [[id:other][thing]] more" })
local ctx3 = {
  bufnr = sb3,
  win = vim.api.nvim_get_current_win(),
  cursor = { 1, 10 },
  cword = "id",
  in_link = true,
  in_comment = false,
}
find.make_insert_link_action(ctx3)(item)
local line3 = vim.api.nvim_buf_get_lines(sb3, 0, 1, false)[1]
assert(line3 == "see [[id:other][thing]] more", "expected refuse (no change), got: " .. line3)

-- insert_link inside a comment: refuses.
local sb4 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(sb4)
vim.api.nvim_buf_set_lines(sb4, 0, -1, false, { "# this is a comment" })
local ctx4 = {
  bufnr = sb4,
  win = vim.api.nvim_get_current_win(),
  cursor = { 1, 5 },
  cword = "this",
  in_link = false,
  in_comment = true,
}
find.make_insert_link_action(ctx4)(item)
local line4 = vim.api.nvim_buf_get_lines(sb4, 0, 1, false)[1]
assert(line4 == "# this is a comment", "expected refuse (no change), got: " .. line4)

vim.fn.delete(tmp, "rf")
io.write("find actions ok\n")
os.exit(0)
