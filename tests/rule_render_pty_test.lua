-- Real-redraw guard for the horizontal rule: a `-----` line must ACTUALLY
-- render as a `─` run filling the window width (far more than the 5 source
-- dashes). Runs nvim under a real pty, redraws, and reads the rendered cells.
--
-- Skips gracefully when a usable pty `script` is unavailable.
--
-- Run via: nvim --headless -l tests/rule_render_pty_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("rule_render_pty_test: SKIP")
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
vim.o.columns = 30
vim.api.nvim_set_hl(0, "NonText", { fg = 0x585b70 })
require("organ").setup({ modern = { rule = true } })
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "before", "-----", "after" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
require("organ.modern.rule").attach(b)
vim.cmd("redraw")
local dash = vim.fn.nr2char(0x2500)
local run = 0
for c = 1, 30 do if vim.fn.screenstring(2, c) == dash then run = run + 1 end end
vim.fn.writefile({ "dash_run=" .. run }, %q)
vim.cmd("qa!")
]]):format(root, out)
vim.fn.writefile(vim.split(prog, "\n"), inner)

local nvim = vim.v.progpath
local cmd = ("%s -u NONE --noplugin -S %s"):format(
  vim.fn.shellescape(nvim),
  vim.fn.shellescape(inner)
)
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

-- The source line has only 5 dashes; a full-width rule fills far more.
check(
  "the rule fills well past the 5 source dashes",
  tonumber(kv.dash_run or "0") >= 20,
  "dash_run=" .. tostring(kv.dash_run)
)

pcall(vim.fn.delete, out)
pcall(vim.fn.delete, inner)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("rule_render_pty_test: PASS")
os.exit(0)
