-- organ.path.write_atomic: write to `.tmp.<rand>`, fsync, rename.
-- Survives crash mid-write AND power loss between write and rename
-- (fsync ensures bytes are durable before rename). Optional `.bak`
-- via `opts.keep_bak` or config.write.keep_bak.
--
-- Run via: nvim --headless -l tests/path_atomic_write_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
local path = require("organ.path")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname() .. "/organ_atomic_test"
vim.fn.mkdir(tmp, "p")

-- 1. Basic write succeeds + returns true.
local target = tmp .. "/file.txt"
local ok, err = path.write_atomic(target, "hello world")
check("basic: returns true on success", ok == true, "err=" .. tostring(err))
check("basic: file exists with expected contents", vim.fn.readfile(target)[1] == "hello world")

-- 2. No leftover .tmp.* file after a successful write.
local function any_tmp_in(dir)
  local fd = vim.uv.fs_scandir(dir)
  while fd do
    local n = vim.uv.fs_scandir_next(fd)
    if not n then
      break
    end
    if n:find("%.tmp%.") then
      return n
    end
  end
end
check("basic: no leftover .tmp.* file after success", any_tmp_in(tmp) == nil)

-- 3. Overwrite existing file — old content replaced atomically.
path.write_atomic(target, "original")
path.write_atomic(target, "replaced")
check("overwrite: new content visible", vim.fn.readfile(target)[1] == "replaced")
check("overwrite default: NO .bak created", vim.fn.filereadable(target .. ".bak") == 0)

-- 4. Parent directory auto-created.
local nested = tmp .. "/a/b/c/file.txt"
local ok2 = path.write_atomic(nested, "nested")
check(
  "nested: parent directories created",
  ok2 == true and vim.fn.readfile(nested)[1] == "nested",
  "ok=" .. tostring(ok2)
)

-- 5. Empty path → returns false (defensive).
local ok3, err3 = path.write_atomic("", "x")
check("empty path: returns false + error", ok3 == false and type(err3) == "string")

-- 6. Nil path → returns false.
local ok4, err4 = path.write_atomic(nil, "x")
check("nil path: returns false + error", ok4 == false and type(err4) == "string")

-- 7. opts.keep_bak: previous version is preserved as .bak BEFORE the
-- new content lands. Mirrors what an editor would do (~vim's `:set
-- backup` workflow), useful for paranoid setups where a crash
-- between write and the next backup must still leave the prior
-- version recoverable.
local bak_target = tmp .. "/with-bak.txt"
path.write_atomic(bak_target, "v1")
path.write_atomic(bak_target, "v2", { keep_bak = true })
check("keep_bak per-call: .bak created", vim.fn.filereadable(bak_target .. ".bak") == 1)
check(
  "keep_bak per-call: .bak holds the PRIOR content (v1)",
  vim.fn.readfile(bak_target .. ".bak")[1] == "v1"
)
check(
  "keep_bak per-call: target holds the NEW content (v2)",
  vim.fn.readfile(bak_target)[1] == "v2"
)

-- 8. Config-level keep_bak: same effect via config.write.keep_bak.
require("organ").config.write = { keep_bak = true }
local cfg_target = tmp .. "/cfg-bak.txt"
path.write_atomic(cfg_target, "first")
path.write_atomic(cfg_target, "second")
check("keep_bak via config: .bak created", vim.fn.filereadable(cfg_target .. ".bak") == 1)
check(
  "keep_bak via config: .bak content is 'first'",
  vim.fn.readfile(cfg_target .. ".bak")[1] == "first"
)
require("organ").config.write = { keep_bak = false }

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("path_atomic_write_test: PASS")
