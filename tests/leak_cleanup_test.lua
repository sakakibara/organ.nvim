-- Ensures per-buffer module state is cleared when an org buffer is wiped.
-- Regression test for the leaks identified 2026-04-27.

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})

local fold = require("organ.fold")
local complete = require("organ.complete")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- Open a buffer with .org filetype, populate fold._state and
-- complete._open_for entries for it, wipe it, verify cleanup.
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(b, "/tmp/leak_test.org")
vim.bo[b].filetype = "org"
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H", "  body" })

fold._state[b] = { [1] = "folded" }
complete._open_for[b] = "1:0"

assert(fold._state[b], "fold state set")
assert(complete._open_for[b], "complete state set")

-- Wipe the buffer.
vim.api.nvim_buf_delete(b, { force = true })

-- BufWipeout fires synchronously inside nvim_buf_delete; cleanup should have run.
assert_eq(fold._state[b], nil, "fold state cleared on BufWipeout")
assert_eq(complete._open_for[b], nil, "complete state cleared on BufWipeout")

io.write("leak cleanup ok\n")
os.exit(0)
