-- Regression: modern block frames + indent mode together. The indent pad is
-- an inline virt_text at column 0; so is the block's `│` side bar. If the pad
-- renders inside the frame (right of `│`), the body overflows the frame's
-- right edge. The indent pad must render leftmost (outside the frame) so the
-- whole block shifts as a unit and the box still closes.
--
-- This runs nvim under a real pty, redraws, and checks the top `╮`, the body's
-- right `│`, and the bottom `╯` all land in the same column.
--
-- Run via: nvim --headless -l tests/indent_blocks_render_pty_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("indent_blocks_render_pty_test: SKIP")
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
vim.o.columns = 48
require("organ").setup({ modern = { blocks = true }, indent = { enabled = true } })
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* Heading", "#+begin_src lua", "print('hi')", "#+end_src" })
vim.bo[b].filetype = "org"
vim.wo.conceallevel = 2
vim.wo.concealcursor = "nc"
pcall(vim.treesitter.start, b, "org")
require("organ.modern.blocks").attach(b)
require("organ.indent").attach(b)
vim.cmd("redraw")
local tr = vim.fn.nr2char(0x256e) -- ╮ top-right
local bar = vim.fn.nr2char(0x2502) -- │ side bar
local brc = vim.fn.nr2char(0x256f) -- ╯ bottom-right
local function last_col(scr_row, ch)
  local col
  for c = 1, 48 do if vim.fn.screenstring(scr_row, c) == ch then col = c end end
  return col
end
vim.fn.writefile({
  "top_right=" .. tostring(last_col(2, tr)),
  "body_right=" .. tostring(last_col(3, bar)),
  "bot_right=" .. tostring(last_col(4, brc)),
}, %q)
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

local top, body, bot = kv.top_right, kv.body_right, kv.bot_right
check(
  "all three frame right edges rendered",
  top ~= "nil" and body ~= "nil" and bot ~= "nil",
  "top=" .. tostring(top) .. " body=" .. tostring(body) .. " bot=" .. tostring(bot)
)
check(
  "top ╮ and bottom ╯ align",
  top == bot,
  "top=" .. tostring(top) .. " bot=" .. tostring(bot)
)
check(
  "body does not overflow the frame right edge",
  body == top,
  "body_right=" .. tostring(body) .. " top_right=" .. tostring(top)
)

pcall(vim.fn.delete, out)
pcall(vim.fn.delete, inner)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("indent_blocks_render_pty_test: PASS")
os.exit(0)
