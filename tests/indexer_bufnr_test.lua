-- Assert indexer.extract accepts a bufnr and returns the same headline shape
-- as the string-source call.
-- Run via: nvim --headless -l tests/indexer_bufnr_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
local fixture = root .. "/tests/fixtures/01-headlines.org"

local indexer = require("organ.indexer")

-- Cold string parse as the ground truth.
local src = table.concat(vim.fn.readfile(fixture), "\n") .. "\n"
local ref = indexer.extract(src, fixture, parser_path)

-- Buffer-based call.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(fixture))
vim.api.nvim_buf_set_name(buf, fixture)
vim.bo[buf].filetype = "org"

local got = indexer.extract(buf, fixture, parser_path)
assert(#got == #ref, string.format("bufnr count %d vs ref %d", #got, #ref))
for i = 1, #ref do
  assert(got[i].title == ref[i].title, string.format("row %d title mismatch", i))
  assert(got[i].level == ref[i].level)
end

io.write("indexer bufnr ok\n")
os.exit(0)
