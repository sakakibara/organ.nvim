-- Assert setup() recovers a corrupt DB file when auto_recover=true.
-- Run via: nvim --headless -l tests/corruption_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/corrupt.db"

-- Write garbage to simulate corruption.
local f = io.open(db_path, "w")
f:write("this is definitely not sqlite")
f:close()

local organ = require("organ")
organ.setup({
  db_path = db_path,
  org_dir = tmp,
  notify = false,
  auto_recover = true,
  scan_on_startup = false,
})

-- Trigger lazy DB open: this is where corruption detection + recovery fires.
local h_organ = organ.db_handle()
assert(h_organ, "db_handle() returned nil after recovery")

-- If recovery worked, db_path is now a fresh SQLite DB.
local db = require("organ.db")
local h, err = db.open(db_path)
assert(h, "post-recovery open failed: " .. tostring(err))
local s = assert(h:prepare("PRAGMA user_version"))
assert(s:step() == db.SQLITE_ROW)
assert(s:column_int(0) == 1)
s:finalize()
h:close()

-- A .corrupt. backup file must exist.
local pattern = db_path .. ".corrupt."
local found = false
for _, name in ipairs(vim.fn.glob(db_path .. ".corrupt.*", true, true)) do
  if name:sub(1, #pattern) == pattern then
    found = true
  end
end
assert(found, "no .corrupt backup found")

vim.fn.delete(tmp, "rf")
io.write("corruption recovery ok\n")
os.exit(0)
