-- Every inlinetask must attach to its containing headline in documentSymbol
-- output -- a second+ inlinetask under a different headline must not be
-- dropped.  Guards the inlinetask-attachment path against regressions.
-- Run via: nvim --headless -l tests/lsp_inlinetask_symbols_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local lsp = require("organ.lsp")
local H = lsp._handlers

vim.fn.mkdir("/tmp/lsp_it", "p")
local fixture = "/tmp/lsp_it/foo.org"
vim.fn.writefile({
  "* H1",
  "*************** TODO inline one",
  "*************** END",
  "* H2",
  "*************** TODO inline two",
  "*************** END",
}, fixture)
local bufnr = vim.fn.bufadd(fixture)
vim.fn.bufload(bufnr)
vim.bo[bufnr].filetype = "org"

local URI = vim.uri_from_fname(fixture)
local syms = H["textDocument/documentSymbol"]({ textDocument = { uri = URI } })

local function child_names(sym)
  local names = {}
  for _, c in ipairs(sym.children or {}) do
    names[#names + 1] = c.name
  end
  return table.concat(names, ",")
end

assert(#syms == 2, "two top-level headlines, got " .. #syms)
assert(syms[1].name == "H1" and syms[2].name == "H2", "headline names")
assert(
  child_names(syms[1]):find("inline one", 1, true),
  "H1 has its inlinetask: " .. child_names(syms[1])
)
assert(
  child_names(syms[2]):find("inline two", 1, true),
  "H2 has its inlinetask: " .. child_names(syms[2])
)

print("lsp_inlinetask_symbols_test: PASS")
