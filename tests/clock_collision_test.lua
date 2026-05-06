-- Auto-stop on second clock-in (drift from Emacs prompt).
-- Run via: nvim --headless -l tests/clock_collision_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local data_dir = tmp .. "/data"
vim.fn.mkdir(data_dir, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(w)
  if w == "data" then
    return data_dir
  end
  return original_stdpath(w)
end

local fixture = vim.fn.resolve(org_dir .. "/x.org")
local f = assert(io.open(fixture, "w"))
f:write([=[* Alpha
  :PROPERTIES:
  :ID: alpha
  :END:

* Beta
  :PROPERTIES:
  :ID: beta
  :END:
]=])
f:close()

require("organ").setup({
  db_path = tmp .. "/c.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  mtime_skip = false,
  hash_skip = false,
})
require("organ").scan_blocking(org_dir, 5000)

vim.cmd("edit " .. vim.fn.fnameescape(fixture))
local bufnr = vim.api.nvim_get_current_buf()
vim.bo.filetype = "org"

local clock = require("organ.clock")
local state_mod = require("organ.clock.state")

-- Clock-in on Alpha (line 1).
clock.start({ bufnr = bufnr, line = 1 })
local s1 = state_mod.load()
assert(s1 and s1.headline_id == "alpha")

-- Clock-in on Beta (find its line).
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local beta_line
for i, l in ipairs(lines) do
  if l:match("^%* Beta") then
    beta_line = i
    break
  end
end
assert(beta_line, "Beta headline not found")

clock.start({ bufnr = bufnr, line = beta_line })

-- State should now point at Beta.
local s2 = state_mod.load()
assert(
  s2 and s2.headline_id == "beta",
  "state should flip to beta; got " .. tostring(s2 and s2.headline_id)
)

-- Alpha should have a closed CLOCK line (auto-stopped).
local lines2 = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local alpha_closed
for _, l in ipairs(lines2) do
  if l:match("CLOCK:.*%-%-%[.*=>") then
    alpha_closed = l
    break
  end
end
assert(alpha_closed, "Alpha CLOCK should be closed; got\n" .. table.concat(lines2, "\n"))

-- Beta should have an active CLOCK line.
local beta_active
for i = beta_line, #lines2 do
  if lines2[i]:match("CLOCK:%s*%[[^%]]+%]%s*$") then
    beta_active = lines2[i]
    break
  end
end
assert(beta_active, "Beta should have an active CLOCK line")

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmp, "rf")
io.write("clock collision ok\n")
os.exit(0)
