local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})
local import = require("organ.import")

assert(type(import.commands) == "table", "import module exposes a commands registry")
local entry = import.commands["import markdown"]
assert(entry and type(entry.fn) == "function", "import markdown command registered")
assert(entry.complete == "file" and entry.bang == true, "command opts mirror export")

-- Importing a markdown file opens an org buffer with the converted content.
local mdfile = "/tmp/organ_import_test.md"
vim.fn.writefile({ "hello world", "", "second para" }, mdfile)
entry.fn({ fargs = { mdfile }, args = mdfile, bang = false })
local buf_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(buf_text:find("hello world", 1, true), "imported buffer has the first paragraph")
assert(buf_text:find("second para", 1, true), "imported buffer has the second paragraph")
assert(vim.bo.filetype == "org", "imported buffer is filetype=org")

print("import_command_test: PASS")
