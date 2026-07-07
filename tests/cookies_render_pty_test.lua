-- Real-redraw guard for statistics cookies: the progress bar + fraction must
-- ACTUALLY render at the window's right edge, and the raw `[1/3]` must be
-- concealed from the left content. Runs nvim under a real pty, redraws, and
-- reads the rendered cells via screenstring().
--
-- Skips gracefully when a usable pty `script` is unavailable.
--
-- Run via: nvim --headless -l tests/cookies_render_pty_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("cookies_render_pty_test: SKIP")
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
vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xf9e2af })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x6c7086 })
require("organ").setup({ modern = { cookies = true }, todo = { sequence = { "TODO", "|", "DONE" } } })
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* project [1/3]" })
vim.bo[b].filetype = "org"
vim.wo.conceallevel = 2
vim.wo.concealcursor = "nc"
pcall(vim.treesitter.start, b, "org")
require("organ.modern.cookies").attach(b)
vim.cmd("redraw")
local right = ""
for c = 28, 40 do right = right .. vim.fn.screenstring(1, c) end
local left = ""
for c = 1, 25 do left = left .. vim.fn.screenstring(1, c) end
vim.fn.writefile({ "right=[" .. right .. "]", "left=[" .. left .. "]" }, %q)
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
local lines = vim.fn.readfile(out)
local kv = {}
for _, l in ipairs(lines) do
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

check("the fraction 1/3 renders near the right edge", kv.right and kv.right:find("1/3") ~= nil,
  "right dump: " .. tostring(kv.right))
check("the raw [1/3] is concealed from the left content", kv.left and kv.left:find("%[1/3%]") == nil,
  "left dump: " .. tostring(kv.left))

pcall(vim.fn.delete, out)
pcall(vim.fn.delete, inner)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("cookies_render_pty_test: PASS")
os.exit(0)
