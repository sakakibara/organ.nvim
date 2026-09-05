-- Wiping an org buffer must release every per-buffer resource keyed by its
-- bufnr: the `#+TODO:` augroup name and the foldexpr / foldtext caches.
-- Run via: nvim --headless -l tests/ftplugin_wipe_cleanup_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({ notify = false, scan_on_startup = false, watcher = { enabled = false } })

local fold = require("organ.fold")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function with_fold(foldstart, foldend, fn)
  local s, e = vim.v.foldstart, vim.v.foldend
  vim.cmd("let v:foldstart = " .. foldstart)
  vim.cmd("let v:foldend = " .. foldend)
  local out = fn()
  vim.cmd("let v:foldstart = " .. s)
  vim.cmd("let v:foldend = " .. e)
  return out
end

local wiped = {}

local function cycle()
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "#+TODO: WAIT | DONE", "* WAIT H", "body" })
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.cmd("doautocmd FileType org")
  pcall(vim.treesitter.start, b, "org")
  -- Populate both fold caches for this buffer.
  fold.foldexpr(2)
  with_fold(2, 3, function()
    return fold.foldtext()
  end)
  assert(fold._foldcache[b], "foldexpr cache not populated")
  assert(fold._ts_seg_cache[b], "foldtext segment cache not populated")
  wiped[#wiped + 1] = b
  vim.cmd("enew")
  vim.cmd("bwipeout! " .. b)
end

cycle()
local before_groups = #vim.fn.getcompletion("organ_buftodo_", "augroup")
for _ = 1, 3 do
  cycle()
end
local after_groups = #vim.fn.getcompletion("organ_buftodo_", "augroup")

check(
  "no organ_buftodo_<bufnr> augroup survives a wipe cycle",
  after_groups == before_groups,
  ("before=%d after=%d"):format(before_groups, after_groups)
)

local stale = {}
for _, b in ipairs(wiped) do
  if fold._foldcache[b] then
    stale[#stale + 1] = "foldcache[" .. b .. "]"
  end
  if fold._ts_seg_cache[b] then
    stale[#stale + 1] = "ts_seg_cache[" .. b .. "]"
  end
end
check("fold caches dropped for wiped buffers", #stale == 0, table.concat(stale, " "))

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
io.write("ftplugin_wipe_cleanup ok\n")
os.exit(0)
