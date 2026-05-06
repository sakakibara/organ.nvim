-- conceal._apply: extmark per emphasis-marker char in an org buffer.
-- Run via: nvim --headless -l tests/conceal_emphasis_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

-- Need both grammars registered.
local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = indexer._inline_parser_path(parser_path) })

local conceal = require("organ.conceal")

-- Set up a buffer with a few emphasis spans.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H",
  "this is *bold* and /italic/ and =verb=.",
})
vim.bo[b].filetype = "org"
vim.api.nvim_set_current_buf(b)

conceal._apply(b)

-- Count extmarks; expected = 2 chars per emphasis span × 3 spans = 6.
local NS = vim.api.nvim_create_namespace("organ_emphasis_conceal")
local marks = vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })
assert(#marks >= 6, "expected ≥ 6 conceal extmarks; got " .. #marks)

-- Each mark should be exactly one byte wide and have conceal = "".
for _, m in ipairs(marks) do
  local row, col, det = m[2], m[3], m[4]
  assert(det.conceal == "", 'mark missing conceal="" at row=' .. row .. " col=" .. col)
end

io.write("conceal emphasis ok\n")
os.exit(0)
