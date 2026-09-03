-- `:Org lsp stop` calls `client:stop()`, which sends `shutdown` then
-- `exit` to the in-process server.  The server must report its exit
-- through the client's dispatchers so Neovim drops the client, and a
-- later `attach()` must start a fresh client instead of reusing the
-- stopped one.
--
-- Run via: nvim --headless -l tests/lsp_stop_restart_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "* A", "** B" }, dir .. "/a.org")
vim.cmd("edit " .. dir .. "/a.org")
if vim.bo.filetype ~= "org" then
  vim.bo.filetype = "org"
end
vim.wait(200)
local bufnr = vim.api.nvim_get_current_buf()

local function clients()
  return vim.lsp.get_clients({ name = "organ" })
end
check("one organ client after open", #clients() == 1, "got " .. #clients())
local c = clients()[1]
local old_id = c.id

c:stop()
vim.wait(3000, function()
  return #clients() == 0
end, 50)
check("client is gone after stop()", #clients() == 0, "still listed: " .. #clients())
check("stopped client's rpc is closing", c.rpc.is_closing() == true)

local new_id = require("organ.lsp").attach(bufnr)
check(
  "attach() after stop starts a new client",
  new_id ~= nil and new_id ~= old_id,
  "got " .. tostring(new_id)
)
vim.wait(200)
check("new client listed", #clients() == 1, "got " .. #clients())
local res = vim.lsp.buf_request_sync(
  bufnr,
  "textDocument/documentSymbol",
  { textDocument = { uri = vim.uri_from_fname(dir .. "/a.org") } },
  2000
)
local n = 0
for _, r in pairs(res or {}) do
  n = n + #(r.result or {})
end
check("new client answers documentSymbol", n == 1, "got " .. n)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("lsp_stop_restart_test: PASS")
os.exit(0)
