-- organ.goto.outline: build slash-joined ancestor paths for every headline.
-- Run via: nvim --headless -l tests/goto_outline_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local g = require("organ.goto")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fixture = tmp .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[* Top
  body
** Sub :tag1:tag2:
   body
*** Deep
*** TODO [#A] Other :work:
* Sibling
]])
fh:close()
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

local out = g.outline(b)
assert(#out == 5, "expected 5 headlines, got " .. #out)

assert(out[1].title == "Top", "1.title: " .. out[1].title)
assert(out[1].path == "Top", "1.path: " .. out[1].path)
assert(out[1].level == 1)
assert(out[1].line == 1)

assert(out[2].title == "Sub", "2.title: " .. out[2].title)
assert(out[2].path == "Top / Sub", "2.path: " .. out[2].path)
assert(out[2].level == 2)

assert(out[3].title == "Deep", "3.title: " .. out[3].title)
assert(out[3].path == "Top / Sub / Deep", "3.path: " .. out[3].path)

-- TODO keyword + priority cookie are stripped from title; tag block is stripped.
assert(out[4].title == "Other", "4.title: " .. out[4].title)
assert(out[4].path == "Top / Sub / Other", "4.path: " .. out[4].path)

-- Sibling resets the ancestor stack for level 1.
assert(out[5].title == "Sibling", "5.title: " .. out[5].title)
assert(out[5].path == "Sibling", "5.path: " .. out[5].path)

vim.fn.delete(tmp, "rf")
io.write("goto outline ok\n")
os.exit(0)
