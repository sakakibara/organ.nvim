-- The modern engine registers window-scoped autocmds (WinScrolled /
-- WinResized) that Neovim cannot remove with the buffer, so wiping a
-- decorated buffer must tear the whole augroup down.  Counting autocmds
-- across open-and-wipe cycles catches any future registration that
-- outlives its buffer, not just these two.
-- Run via: nvim --headless -l tests/modern_render_autocmd_leak_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  modern = "all",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
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

local function autocmd_count()
  return #vim.api.nvim_get_autocmds({})
end

local function cycle()
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H", "- [ ] x", "body" })
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  vim.cmd("doautocmd FileType org")
  local group = "organ_modern_render_" .. b
  assert(#vim.api.nvim_get_autocmds({ group = group }) > 0, "engine did not attach")
  vim.cmd("enew")
  vim.cmd("bwipeout! " .. b)
end

-- One warm-up cycle so lazily-required modules have registered whatever
-- global autocmds they own; the measured cycles then only differ by
-- per-buffer registrations.
cycle()
local before = autocmd_count()
for _ = 1, 3 do
  cycle()
end
local after = autocmd_count()

check(
  "no autocmds survive an open-and-wipe cycle",
  after == before,
  ("before=%d after=%d"):format(before, after)
)

local leftover = 0
for _, c in ipairs(vim.api.nvim_get_autocmds({})) do
  if c.group_name and c.group_name:match("^organ_modern_render_%d") then
    leftover = leftover + 1
  end
end
check("no organ_modern_render_<bufnr> autocmds left", leftover == 0, "got " .. leftover)

if fails > 0 then
  print("\nFAILED " .. fails .. " checks")
  os.exit(1)
end
io.write("modern_render_autocmd_leak ok\n")
os.exit(0)
