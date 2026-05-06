-- attach.git: when enabled, every attach auto-inits the dir as a git
-- repo and commits the new file.
-- Run via: nvim --headless -l tests/attach_git_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

if vim.fn.executable("git") ~= 1 then
  io.write("attach git: SKIP (git not on PATH)\n")
  os.exit(0)
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local data_dir = tmp .. "/data"
vim.fn.mkdir(data_dir, "p")

-- Hermetic git env: don't inherit the dev's global config (which may
-- enable commit.gpgsign and need a signing agent the test sandbox
-- doesn't run). Empty config files work cross-platform.
local empty_cfg = tmp .. "/empty.gitconfig"
io.open(empty_cfg, "w"):close()
vim.env.GIT_CONFIG_GLOBAL = empty_cfg
vim.env.GIT_CONFIG_SYSTEM = empty_cfg

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  attach = { enabled = true, dir = data_dir, git = true, auto_insert_link = false },
})

local attach = require("organ.attach")

-- Set up a fixture buffer with a headline that already has an :ID:.
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[* Heading
  :PROPERTIES:
  :ID: abcdefgh-1234-5678
  :END:
]])
fh:close()
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

-- A source file to attach.
local src = tmp .. "/sample.txt"
local fs = assert(io.open(src, "w"))
fs:write("hello world\n")
fs:close()

local err = attach.attach(b, 1, src)
assert(err == nil, "attach failed: " .. tostring(err))

-- The headline's attachment dir should now be a git repo with one commit.
local id = "abcdefgh-1234-5678"
local hl_dir = data_dir .. "/" .. id:sub(1, 2) .. "/" .. id:sub(3)
assert(vim.uv.fs_stat(hl_dir .. "/.git"), ".git dir should exist at " .. hl_dir)

local rc = os.execute(
  string.format("git -C %s log --oneline 2>&1 | grep -q 'sample.txt'", vim.fn.shellescape(hl_dir))
)
assert(rc == 0 or rc == true, "expected commit referencing sample.txt")

-- A second attach should produce a second commit.
local src2 = tmp .. "/another.txt"
fs = assert(io.open(src2, "w"))
fs:write("more\n")
fs:close()
err = attach.attach(b, 1, src2)
assert(err == nil, "second attach: " .. tostring(err))

local out = vim.fn.system({ "git", "-C", hl_dir, "log", "--oneline" })
local n_lines = 0
for _ in out:gmatch("\n") do
  n_lines = n_lines + 1
end
assert(n_lines == 2, "expected 2 commits; got " .. n_lines .. "\n" .. out)

vim.fn.delete(tmp, "rf")
io.write("attach git ok\n")
os.exit(0)
