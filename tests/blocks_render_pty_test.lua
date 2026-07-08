-- Real-redraw guard for block frames: the rounded top corner must render, AND
-- the inline body side bar `│` must render before the body text. The side bar
-- is the migration's payoff -- the ephemeral decoration provider silently
-- dropped inline virt_text, so it never appeared; the persistent engine draws
-- it. Runs nvim under a real pty, redraws, reads cells via screenstring().
--
-- Skips gracefully when a usable pty `script` is unavailable.
--
-- Run via: nvim --headless -l tests/blocks_render_pty_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("blocks_render_pty_test: SKIP")
  os.exit(0)
end

if vim.fn.executable("script") ~= 1 then
  skip("no `script` binary for a pty")
end

local out = vim.fn.tempname() .. ".txt"
local inner = vim.fn.tempname() .. ".lua"

local prog = ([[
local root = %q
dofile(root .. "/tests/_bootstrap.lua")
vim.o.columns = 40
require("organ").setup({ modern = { blocks = true } })
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "#+begin_src lua", "print('hi')", "#+end_src" })
vim.bo[b].filetype = "org"
vim.wo.concealcursor = "nc"
pcall(vim.treesitter.start, b, "org")
require("organ.modern.blocks").attach(b)
vim.cmd("redraw")
local tl = vim.fn.nr2char(0x256d)  -- ╭
local bar = vim.fn.nr2char(0x2502) -- │
local tl_found, bar_col, print_col = "nil", nil, nil
for c = 1, 40 do if vim.fn.screenstring(1, c) == tl then tl_found = tostring(c) break end end
for c = 1, 40 do
  local s = vim.fn.screenstring(2, c)
  if s == bar and not bar_col then bar_col = c end
  if s == "p" and not print_col then print_col = c end
end
vim.fn.writefile({
  "tl_found=" .. tl_found,
  "bar_before_print=" .. tostring(bar_col ~= nil and print_col ~= nil and bar_col < print_col),
}, %q)
vim.cmd("qa!")
]]):format(root, out)
vim.fn.writefile(vim.split(prog, "\n"), inner)

local nvim = vim.v.progpath
local cmd = ("%s -u NONE --noplugin -S %s"):format(vim.fn.shellescape(nvim), vim.fn.shellescape(inner))
local sys = (vim.uv or vim.loop).os_uname().sysname
local invocation
if sys == "Darwin" then
  invocation = ("script -q /dev/null %s >/dev/null 2>&1"):format(cmd)
else
  invocation = ("script -qec %s /dev/null >/dev/null 2>&1"):format(vim.fn.shellescape(cmd))
end
os.execute(invocation)

if vim.fn.filereadable(out) ~= 1 then
  skip("pty run produced no screen dump (script variant mismatch?)")
end
local kv = {}
for _, l in ipairs(vim.fn.readfile(out)) do
  local k, v = l:match("^([%w_]+)=(.*)$")
  if k then
    kv[k] = v
  end
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

check("rounded top corner renders", kv.tl_found ~= nil and kv.tl_found ~= "nil", "tl_found=" .. tostring(kv.tl_found))
check("inline body side bar renders before the body text", kv.bar_before_print == "true",
  "bar_before_print=" .. tostring(kv.bar_before_print))

pcall(vim.fn.delete, out)
pcall(vim.fn.delete, inner)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("blocks_render_pty_test: PASS")
os.exit(0)
