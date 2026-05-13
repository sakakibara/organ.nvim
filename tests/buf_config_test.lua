-- Per-buffer config override layer.  Verifies read/set/toggle/unset/reset
-- semantics, dotted-path handling, reapply-hook firing, and the BufWipeout
-- autocmd that cleans up overrides when a buffer goes away.
--
-- Run via: nvim --headless -l tests/buf_config_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  indent = { enabled = false, shift_per_level = 2 },
  modern = { bullets = false },
})

local bc = require("organ.buf_config")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(false, true)
vim.bo[b].filetype = "org"

-- 1. effective(bufnr) returns global when no overrides are set.
check("effective falls back to global when no overrides", bc.read(b, "indent.shift_per_level") == 2)

-- 2. set + read for a single boolean.
bc.set(b, "indent.enabled", true)
check("set + read returns the override value", bc.read(b, "indent.enabled") == true)

-- 3. set creates intermediate tables for nested paths.
bc.set(b, "x.y.z", 42)
check("set creates intermediate tables", bc.read(b, "x.y.z") == 42)

-- 4. toggle flips a boolean correctly.
bc.set(b, "modern.bullets", true)
local new1 = bc.toggle(b, "modern.bullets")
check("toggle of true returns false", new1 == false)
check("read after toggle reflects new value", bc.read(b, "modern.bullets") == false)
local new2 = bc.toggle(b, "modern.bullets")
check("toggle of false returns true", new2 == true)

-- 5. toggle on a non-boolean truthy value flips to false.
bc.set(b, "n", 1)
local new3 = bc.toggle(b, "n")
check("toggle of non-boolean truthy returns false", new3 == false)

-- 6. unset reverts to global value.
check("read before unset returns override", bc.read(b, "indent.enabled") == true)
bc.unset(b, "indent.enabled")
-- setup() above passed indent = { enabled = false, ... } so global is false.
check(
  "read after unset returns global (false)",
  bc.read(b, "indent.enabled") == false,
  "got " .. tostring(bc.read(b, "indent.enabled"))
)

-- 7. reset wipes all buf overrides.
bc.set(b, "a.b", "hello")
bc.set(b, "c", 5)
check("read sees override after set", bc.read(b, "a.b") == "hello")
bc.reset(b)
check("read after reset falls back to global (nil)", bc.read(b, "a.b") == nil)
check("read after reset falls back to global for `c`", bc.read(b, "c") == nil)

-- 8. on_reapply hook fires on set/unset/reset.
local fire_count = 0
local last_buf
bc.on_reapply(function(bufnr)
  fire_count = fire_count + 1
  last_buf = bufnr
end)
local pre = fire_count
bc.set(b, "h.k", true)
check("on_reapply fires on set", fire_count == pre + 1, "fire_count = " .. fire_count)
check("on_reapply receives the right bufnr", last_buf == b)
bc.unset(b, "h.k")
check("on_reapply fires on unset", fire_count == pre + 2)
bc.reset(b)
check("on_reapply fires on reset", fire_count == pre + 3)

-- 9. BufWipeout autocmd clears overrides.
local b2 = vim.api.nvim_create_buf(false, true)
bc.set(b2, "indent.enabled", true)
check("override registered on b2", bc.read(b2, "indent.enabled") == true)
vim.api.nvim_buf_delete(b2, { force = true })
-- The autocmd fires synchronously; the underlying table is empty for b2.
local overrides = bc._overrides()
check("BufWipeout clears entry from _overrides", overrides[b2] == nil)

-- 10. effective returns a fresh table when overrides exist (so callers can
-- safely modify it without affecting the global config).
bc.set(b, "fresh.key", "v")
local eff = bc.effective(b)
eff.fresh.key = "mutated"
local re = bc.effective(b)
check(
  "effective returns a fresh table per call",
  re.fresh.key == "v",
  "re.fresh.key = " .. tostring(re.fresh.key)
)

-- 11. paths() enumerates dotted paths from a tree.
local sample = { a = 1, b = { c = 2, d = { e = 3 } } }
local paths = bc.paths(sample)
table.sort(paths)
local has = {}
for _, p in ipairs(paths) do
  has[p] = true
end
check("paths includes leaf 'a'", has["a"])
check("paths includes group 'b'", has["b"])
check("paths includes 'b.c'", has["b.c"])
check("paths includes 'b.d'", has["b.d"])
check("paths includes leaf 'b.d.e'", has["b.d.e"])

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("buf_config_test: PASS")
os.exit(0)
