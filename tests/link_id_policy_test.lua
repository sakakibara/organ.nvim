-- `links.id_link_policy` mirrors Emacs `org-id-link-to-org-use-id`.
-- Default "use-existing" makes `:Org store_link` use an existing :ID:
-- but NOT auto-create one — the fallback is a `file::*Headline` link.
-- "create" preserves the prior auto-:ID: behavior.
--
-- Run via: nvim --headless -l tests/link_id_policy_test.lua

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

-- Two test fixtures: one headline with an existing :ID:, one without.
local tmp = vim.fn.tempname() .. ".org"
local f = assert(io.open(tmp, "w"))
f:write([[
* TODO With ID
  :PROPERTIES:
  :ID:       known-id-12345
  :END:
* TODO Without ID
]])
f:close()

require("organ").setup({
  org_dir = vim.fn.fnamemodify(tmp, ":h"),
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local link = require("organ.link")
local store = require("organ.link_store")

vim.cmd("edit " .. vim.fn.fnameescape(tmp))
local bufnr = vim.api.nvim_get_current_buf()

-- (a) Default "use-existing": uses :ID: when present, falls back to
-- file::*Headline when missing — and does NOT mutate the buffer to
-- add a new :ID:.
require("organ").config.links.id_link_policy = "use-existing"

store.clear()
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on "* TODO With ID"
link.store_link()
local e1 = store.list()[1]
check(
  "use-existing + existing :ID:: stored as id-link",
  e1 and e1.kind == "id" and e1.id == "known-id-12345",
  vim.inspect(e1)
)

store.clear()
vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- on "* TODO Without ID"
local before_lines = vim.api.nvim_buf_line_count(bufnr)
link.store_link()
local after_lines = vim.api.nvim_buf_line_count(bufnr)
local e2 = store.list()[1]
-- Headline text matches Emacs's `file::*Heading` link semantics: the
-- entire heading line after the stars (TODO state + title) so the
-- link resolves by exact heading-line match when followed.
check(
  "use-existing + missing :ID:: stored as file_headline (no :ID: created)",
  e2 and e2.kind == "file_headline" and e2.headline == "TODO Without ID",
  vim.inspect(e2)
)
check(
  "use-existing: buffer NOT mutated to add property drawer",
  after_lines == before_lines,
  ("before=%d after=%d"):format(before_lines, after_lines)
)

-- (b) "create": auto-assigns :ID: on the headline-without-:ID: row.
require("organ").config.links.id_link_policy = "create"

store.clear()
vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- on "* TODO Without ID"
local lines_before = vim.api.nvim_buf_line_count(bufnr)
link.store_link()
local lines_after = vim.api.nvim_buf_line_count(bufnr)
local e3 = store.list()[1]
check(
  "create: stored as id-link",
  e3 and e3.kind == "id" and type(e3.id) == "string" and #e3.id > 0,
  vim.inspect(e3)
)
check(
  "create: property drawer was added (buffer line count grew)",
  lines_after > lines_before,
  ("before=%d after=%d"):format(lines_before, lines_after)
)

-- (c) `false`: never use id; always emit file_headline.
require("organ").config.links.id_link_policy = false

store.clear()
vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on "* TODO With ID"
link.store_link()
local e4 = store.list()[1]
check(
  "policy=false: existing :ID: is NOT used; file_headline instead",
  e4 and e4.kind == "file_headline",
  vim.inspect(e4)
)

require("organ").config.links.id_link_policy = nil
vim.cmd("bdelete!")
os.remove(tmp)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("link_id_policy_test: PASS")
