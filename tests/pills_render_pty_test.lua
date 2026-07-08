-- Real-redraw regression guard: pills must ACTUALLY render their rounded
-- cap on screen, with a space between the bullet and the cap.
--
-- Placing an extmark is not the same as rendering it: Neovim's ephemeral
-- decoration provider silently drops inline virt_text, so an earlier pills
-- implementation placed caps that never appeared. Unit tests that only
-- query nvim_buf_get_extmarks cannot catch that. This test runs nvim under
-- a real pty, redraws, and reads the rendered cells via screenstring().
--
-- Skips gracefully when a usable pty `script` is unavailable (e.g. a
-- different `script` variant) so it never breaks the suite; it is the
-- CI/Linux guard for the ephemeral-inline bug class.
--
-- Run via: nvim --headless -l tests/pills_render_pty_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("pills_render_pty_test: SKIP")
  os.exit(0)
end

if vim.fn.executable("script") ~= 1 then
  skip("no `script` binary for a pty")
end

local out = vim.fn.tempname() .. ".txt"
local inner = vim.fn.tempname() .. ".lua"

-- The script that runs inside the pty nvim.
local prog = ([[
local root = %q
dofile(root .. "/tests/_bootstrap.lua")
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xf38ba8 })
require("organ").setup({ modern = { pills = true }, todo = { sequence = { "TODO", "|", "DONE" } } })
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* TODO milk" })
vim.bo[b].filetype = "org"
pcall(vim.treesitter.start, b, "org")
require("organ.modern.pills").attach(b)
vim.cmd("redraw")
local cap = vim.fn.nr2char(0xe0b6)
local cap_col, before1, before2
for c = 1, 60 do
  if vim.fn.screenstring(1, c) == cap then
    cap_col = c
    before1 = vim.fn.screenstring(1, c - 1)
    before2 = vim.fn.screenstring(1, c - 2)
    break
  end
end
vim.fn.writefile({
  "cap_col=" .. tostring(cap_col),
  "before1=[" .. tostring(before1) .. "]",
  "before2=[" .. tostring(before2) .. "]",
}, %q)
vim.cmd("qa!")
]]):format(root, out)
vim.fn.writefile(vim.split(prog, "\n"), inner)

-- util-linux: `script -qec CMD /dev/null`; BSD/macOS: `script -q /dev/null CMD`.
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

check(
  "left cap glyph renders on screen",
  kv.cap_col ~= nil and kv.cap_col ~= "nil",
  "dump: " .. vim.inspect(lines)
)
check(
  "a space sits between the bullet and the cap",
  kv.before1 == "[ ]",
  "cell before cap = " .. tostring(kv.before1)
)
check(
  "the bullet precedes that space",
  kv.before2 == "[*]",
  "two cells before cap = " .. tostring(kv.before2)
)

pcall(vim.fn.delete, out)
pcall(vim.fn.delete, inner)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("pills_render_pty_test: PASS")
os.exit(0)
