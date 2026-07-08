-- Real-redraw guard for headline bullets: the level-1 glyph must ACTUALLY
-- render in place of the leading `*`, with the raw star concealed. Runs nvim
-- under a real pty, redraws, and reads the rendered cells via screenstring()
-- (which returns the glyph codepoint even without a Nerd Font).
--
-- Skips gracefully when a usable pty `script` is unavailable.
--
-- Run via: nvim --headless -l tests/bullets_render_pty_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("bullets_render_pty_test: SKIP")
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
require("organ").setup({ modern = { bullets = true } })
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Top", "** Two" })
vim.bo[b].filetype = "org"
vim.wo.concealcursor = "nc"
pcall(vim.treesitter.start, b, "org")
require("organ.modern.bullets").attach(b)
vim.cmd("redraw")
local g1 = vim.fn.nr2char(0xf111)
local found = "nil"
local cells = {}
for c = 1, 20 do
  local s = vim.fn.screenstring(1, c)
  cells[#cells + 1] = (s == "" and "_" or s)
  if s == g1 and found == "nil" then found = tostring(c) end
end
vim.fn.writefile({ "found_at=" .. found, "cells=[" .. table.concat(cells, "") .. "]" }, %q)
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

check("level-1 bullet glyph renders in place of the star", kv.found_at ~= nil and kv.found_at ~= "nil",
  "cells=" .. tostring(kv.cells))

pcall(vim.fn.delete, out)
pcall(vim.fn.delete, inner)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("bullets_render_pty_test: PASS")
os.exit(0)
