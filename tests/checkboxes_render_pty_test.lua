-- Real-redraw guard for checkboxes: the state icon must ACTUALLY render in
-- place of the `[X]`, with the raw box concealed. Runs nvim under a real pty,
-- redraws, and reads the rendered cells via screenstring() (which returns the
-- glyph codepoint even when the capture terminal lacks a Nerd Font).
--
-- Skips gracefully when a usable pty `script` is unavailable.
--
-- Run via: nvim --headless -l tests/checkboxes_render_pty_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("checkboxes_render_pty_test: SKIP")
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
vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0xa6e3a1 })
require("organ").setup({ modern = { checkboxes = true } })
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "- [X] done" })
vim.bo[b].filetype = "org"
vim.wo.conceallevel = 2
vim.wo.concealcursor = "nc"
pcall(vim.treesitter.start, b, "org")
require("organ.modern.checkboxes").attach(b)
vim.cmd("redraw")
local icon = vim.fn.nr2char(0xf046)
local icon_col
for c = 1, 20 do if vim.fn.screenstring(1, c) == icon then icon_col = c break end end
local line = ""
for c = 1, 20 do line = line .. vim.fn.screenstring(1, c) end
vim.fn.writefile({ "icon_col=" .. tostring(icon_col), "line=[" .. line .. "]" }, %q)
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

check("checked state icon renders", kv.icon_col ~= nil and kv.icon_col ~= "nil", "line dump: " .. tostring(kv.line))
check("the raw [X] box is concealed", kv.line and kv.line:find("%[X%]") == nil, "line dump: " .. tostring(kv.line))

pcall(vim.fn.delete, out)
pcall(vim.fn.delete, inner)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("checkboxes_render_pty_test: PASS")
os.exit(0)
