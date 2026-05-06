-- Org file open MUST NOT crash nvim when the tree-sitter parser is
-- absent.  ftplugin/org.lua wraps treesitter.start in pcall and warns
-- the user; downstream consumers that touch the parser must also
-- pcall and degrade gracefully.  This test removes the parser from
-- the runtime resolution and exercises the open path.
--
-- Run via: nvim --headless -l tests/missing_parser_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Force "parser not available": stub vim.treesitter.start to error
-- and stub vim.treesitter.get_parser to return nil-equivalent.  That
-- mimics what users see when they haven't installed the grammar.
local orig_start = vim.treesitter.start
local orig_get_parser = vim.treesitter.get_parser
vim.treesitter.start = function()
  error("simulated: parser not available")
end
vim.treesitter.get_parser = function()
  error("simulated: parser not available")
end

-- Open an org buffer.  ftplugin runs.
local ok, err = pcall(function()
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H1", "body", "** H2", "more" })
  vim.bo[b].filetype = "org"
  vim.cmd("doautocmd FileType")
end)
check("ftplugin loads without crashing on missing parser", ok, tostring(err))

-- foldexpr must not crash when called on an org buffer with no parser.
local fold_ok, fold_err = pcall(function()
  local _ = require("organ.fold").foldexpr(1)
end)
check("foldexpr() degrades gracefully", fold_ok, tostring(fold_err))

-- statuscolumn_marker must not crash either.
local sc_ok, sc_err = pcall(function()
  local _ = require("organ.fold").statuscolumn_marker(1)
end)
check("statuscolumn_marker() degrades gracefully", sc_ok, tostring(sc_err))

-- contents.enter / leave must not crash (they use buf_get_lines, not
-- the parser, but verify the lifecycle against a real buffer anyway).
local contents = require("organ.fold.contents")
local ce_ok, ce_err = pcall(function()
  contents.enter(0)
  contents.leave(0)
end)
check("contents.enter/leave degrade gracefully", ce_ok, tostring(ce_err))

vim.treesitter.start = orig_start
vim.treesitter.get_parser = orig_get_parser

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("missing_parser_test: PASS")
os.exit(0)
