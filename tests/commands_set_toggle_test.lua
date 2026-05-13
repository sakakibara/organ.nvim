-- :Org set / toggle / unset / config exercise the per-buffer config
-- override layer and trigger reapply hooks so visual decoration features
-- attach / detach on the fly.
--
-- Run via: nvim --headless -l tests/commands_set_toggle_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  indent = { enabled = false, shift_per_level = 2 },
  modern = { bullets = false },
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

assert(vim.api.nvim_get_commands({}).Org, ":Org dispatcher not registered")
check(":Org set registered", require("organ").cmd("set") ~= nil)
check(":Org toggle registered", require("organ").cmd("toggle") ~= nil)
check(":Org unset registered", require("organ").cmd("unset") ~= nil)
check(":Org config registered", require("organ").cmd("config") ~= nil)
check(
  ":Org indent_mode REMOVED",
  require("organ").cmd("indent_mode") == nil,
  "indent_mode should not be registered anymore"
)

-- Open an org buffer.
local fixture = org_dir .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write("* Top\n** Sub\nBody.\n")
fh:close()
vim.cmd("edit " .. vim.fn.fnameescape(fixture))
vim.bo.filetype = "org"
local b = vim.api.nvim_get_current_buf()

local indent = require("organ.indent")
local bc = require("organ.buf_config")

-- 1. :Org set indent.enabled true flips it AND attaches indent for the buffer.
check("indent initially detached", not indent._attached[b])
vim.cmd("Org set indent.enabled true")
check("indent.enabled flipped via :Org set", bc.read(b, "indent.enabled") == true)
check(":Org set indent.enabled true attaches indent", indent._attached[b] == true)

-- 2. :Org toggle indent.enabled flips it back and detaches.
vim.cmd("Org toggle indent.enabled")
check("indent.enabled toggled to false", bc.read(b, "indent.enabled") == false)
check(":Org toggle detaches indent", not indent._attached[b])

-- 3. :Org toggle a previously-unset boolean flips it from global (false / nil)
-- to true and triggers re-render.
vim.cmd("Org toggle modern.bullets")
check("modern.bullets toggled on via :Org toggle", bc.read(b, "modern.bullets") == true)

-- 4. :Org config prints (non-crashing baseline).
local ok = pcall(function()
  vim.cmd("Org config")
end)
check(":Org config does not crash", ok)
local ok2 = pcall(function()
  vim.cmd("Org config global")
end)
check(":Org config global does not crash", ok2)
local ok3 = pcall(function()
  vim.cmd("Org config buf")
end)
check(":Org config buf does not crash", ok3)

-- 5. :Org unset indent.enabled reverts to global.
vim.cmd("Org set indent.enabled true")
check("re-set indent.enabled = true", bc.read(b, "indent.enabled") == true)
vim.cmd("Org unset indent.enabled")
-- setup() above passed indent.enabled = false so global is false.
check(
  ":Org unset reverts to global (false)",
  bc.read(b, "indent.enabled") == false,
  "got " .. tostring(bc.read(b, "indent.enabled"))
)
check(":Org unset triggers detach via reapply", not indent._attached[b])

-- 6. :Org set with various value types.
vim.cmd("Org set indent.shift_per_level 4")
check(":Org set parses integers", bc.read(b, "indent.shift_per_level") == 4)
vim.cmd("Org set indent.hl_group Comment")
check(":Org set falls back to string", bc.read(b, "indent.hl_group") == "Comment")

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("commands_set_toggle_test: PASS")
os.exit(0)
