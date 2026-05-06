-- publish.lua walk_org_files must defuse symlink loops. Without the
-- realpath/seen guard, a symlink pointing back into the project root
-- causes infinite recursion.
--
-- Run via: nvim --headless -l tests/publish_symlink_loop_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
if vim.fn.filereadable(parser_path) ~= 1 then
  io.write("(skipped: parser not installed)\npublish_symlink_loop_test: SKIP\n")
  os.exit(0)
end
vim.treesitter.language.add("org", { path = parser_path })

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local base = tmp .. "/in"
vim.fn.mkdir(base, "p")
local out = tmp .. "/out"
vim.fn.mkdir(out, "p")

-- Real .org file
do
  local f = assert(io.open(base .. "/a.org", "w"))
  f:write("* Real\nbody\n")
  f:close()
end

-- Create a symlink loop: base/loop → base
local loop_target = base .. "/loop"
local ok = vim.uv.fs_symlink(base, loop_target)
if not ok then
  io.write(
    "(skipped: cannot create symlink — fs may not allow)\npublish_symlink_loop_test: SKIP\n"
  )
  vim.fn.delete(tmp, "rf")
  os.exit(0)
end

require("organ").setup({
  db_path = tmp .. "/x.db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  publish = {
    projects = {
      sym = {
        base_directory = base,
        publishing_directory = out,
        recursive = true,
        publishing_function = "ascii",
      },
    },
  },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Without the seen-set guard, the publish call would recurse forever and
-- this test would hang. We give vim.wait a generous deadline; if it
-- finishes within it, the loop guard worked.
local done, result, err
vim.schedule(function()
  result, err = require("organ.publish").publish("sym")
  done = true
end)
local finished = vim.wait(5000, function()
  return done
end, 50)

check(
  "publish: terminates within 5s on symlink loop (proves seen-set guard)",
  finished,
  "deadline exceeded"
)
check(
  "publish: returns a result (no error)",
  result ~= nil and err == nil,
  "result=" .. vim.inspect(result) .. " err=" .. tostring(err)
)
if result then
  check(
    "publish: indexed the real file exactly once",
    result.total == 1,
    "got total=" .. tostring(result.total)
  )
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("publish_symlink_loop_test: PASS")
