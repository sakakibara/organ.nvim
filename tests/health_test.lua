-- Assert :checkhealth organ produces reports for dylib, parser, DB, and schema.
-- Run via: nvim --headless -l tests/health_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Prime setup so DB/queue are live.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
require("organ").setup({
  db_path = tmp .. "/h.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
})

-- Capture messages from vim.health.
local messages = {}
local orig_ok = vim.health.ok
local orig_warn = vim.health.warn
local orig_error = vim.health.error
vim.health.ok = function(m)
  messages[#messages + 1] = { "ok", m }
end
vim.health.warn = function(m)
  messages[#messages + 1] = { "warn", m }
end
vim.health.error = function(m)
  messages[#messages + 1] = { "error", m }
end

require("organ.health").check()

vim.health.ok = orig_ok
vim.health.warn = orig_warn
vim.health.error = orig_error

local function contains(needle)
  for _, m in ipairs(messages) do
    if m[2]:find(needle, 1, true) then
      return true
    end
  end
  return false
end

assert(contains("libsqlite3"), "no libsqlite3 report")
assert(contains("parser"), "no parser report")
assert(contains("schema"), "no schema report")
assert(contains("db_path") or contains("database"), "no DB report")

vim.fn.delete(tmp, "rf")
io.write("health ok\n")
os.exit(0)
