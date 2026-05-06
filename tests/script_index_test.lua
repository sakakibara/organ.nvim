-- Spawn nvim --headless -l scripts/index.lua <file> against a temp DB,
-- then assert the DB has the expected rows.
-- Run via: nvim --headless -l tests/script_index_test.lua

local root = vim.fn.getcwd()
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local dbp = tmp .. "/index.db"
local fix = root .. "/tests/fixtures/01-headlines.org"

local r = vim
  .system({
    "nvim",
    "--headless",
    "--cmd",
    "set rtp^=" .. root,
    "-l",
    "scripts/index.lua",
    "--db",
    dbp,
    "--file",
    fix,
  }, { text = true })
  :wait()

if r.code ~= 0 then
  io.stderr:write("script exited " .. r.code .. "\nstderr: " .. (r.stderr or "") .. "\n")
  os.exit(1)
end

dofile(root .. "/tests/_bootstrap.lua")
local db = require("organ.db")
local h = assert(db.open(dbp))
local s = assert(h:prepare("SELECT COUNT(*) FROM headlines"))
assert(s:step() == db.SQLITE_ROW)
local n = s:column_int(0)
s:finalize()
assert(n == 7, "expected 7 headlines, got " .. n)
h:close()

vim.fn.delete(tmp, "rf")
io.write("script index ok\n")
os.exit(0)
