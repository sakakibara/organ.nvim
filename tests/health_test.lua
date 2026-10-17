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
for _, grammar in ipairs({ "org.so", "org_inline.so" }) do
  local loads = false
  for _, m in ipairs(messages) do
    loads = loads
      or (m[1] == "ok" and m[2]:find("parser loads: .*" .. grammar:gsub("%.", "%%.")) ~= nil)
  end
  assert(loads, grammar .. " not reported as loading: " .. vim.inspect(messages))
end
assert(contains("schema"), "no schema report")
assert(contains("db_path") or contains("database"), "no DB report")

-- A second run in the same session still checks the file on disk: here
-- a copy of org.so replaced by junk after the first run.
local copy = tmp .. "/parsers"
vim.fn.mkdir(copy, "p")
local gi = require("organ.grammar_install")
for _, f in ipairs({ "org.so", "org_inline.so" }) do
  assert(vim.uv.fs_copyfile(gi.path(f), copy .. "/" .. f))
end
require("organ").config.parser_path = copy .. "/org.so"
local function run_check()
  messages = {}
  vim.health.ok = function(m)
    messages[#messages + 1] = { "ok", m }
  end
  vim.health.error = function(m)
    messages[#messages + 1] = { "error", m }
  end
  vim.health.warn = function(m)
    messages[#messages + 1] = { "warn", m }
  end
  require("organ.health").check()
  vim.health.ok, vim.health.warn, vim.health.error = orig_ok, orig_warn, orig_error
  for _, m in ipairs(messages) do
    if m[2]:find("org.so", 1, true) and m[2]:find(copy, 1, true) then
      return m[1]
    end
  end
end
assert(run_check() == "ok", "the copy loads: " .. vim.inspect(messages))
vim.fn.writefile({ "not a shared object" }, copy .. "/org.so")
assert(run_check() == "error", "a second run must catch the junk file: " .. vim.inspect(messages))

-- A library that kills the process loading it (a stale code signature on
-- macOS does this) is not reported as loading.
if vim.fn.executable("cc") == 1 then
  local src = tmp .. "/crash.c"
  vim.fn.writefile({
    "#include <signal.h>",
    "#include <unistd.h>",
    "__attribute__((constructor)) static void die(void) { kill(getpid(), SIGKILL); }",
    "const void *tree_sitter_org(void) { return 0; }",
  }, src)
  local built = vim
    .system({ "cc", "-shared", "-fPIC", "-o", copy .. "/org.so", src }, { text = true })
    :wait()
  assert(built.code == 0, "could not build the crashing library: " .. built.stderr)
  assert(run_check() == "error", "a crashing library must not pass: " .. vim.inspect(messages))
end

vim.fn.delete(tmp, "rf")
io.write("health ok\n")
os.exit(0)
