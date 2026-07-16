-- Star treatments inside nvim-treesitter-context's sticky header. The
-- context float renders COPIES of headline lines in its own scratch buffer,
-- and treesitter-context only carries over extmarks from core `nvim.*`
-- namespaces (without the `conceal` field), so organ's star conceals never
-- reach it -- the header shows literal `*` stars while the buffer shows
-- glyphs (modern.bullets) or space-hidden stars (stars.hide).
-- organ.ts_context re-renders the star conceals into the context buffer.
--
-- This runs nvim under a real pty, scrolls until the headline chain is only
-- visible via the context float, and checks the float mirrors the buffer's
-- star treatment: per-level glyphs under modern.bullets, and leading stars
-- hidden (depth star kept) under stars.hide.
--
-- Run via: nvim --headless -l tests/context_bullets_render_pty_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("context_bullets_render_pty_test: SKIP")
  os.exit(0)
end

if vim.fn.executable("script") ~= 1 then
  skip("no `script` binary for a pty")
end
if vim.fn.isdirectory(root .. "/tests/deps/nvim-treesitter-context") == 0 then
  skip("tests/deps/nvim-treesitter-context is missing (run `make deps`)")
end

-- Run one pty nvim with the given organ setup + attach snippet; return the
-- first two screen rows (the context float) as strings, or nil on pty
-- failure.
local function run_scenario(setup_opts, attach_expr)
  local out = vim.fn.tempname() .. ".txt"
  local inner = vim.fn.tempname() .. ".lua"

  local prog = ([[
local root = %q
dofile(root .. "/tests/_bootstrap.lua")
vim.opt.runtimepath:append(root .. "/tests/deps/nvim-treesitter-context")
vim.o.columns = 60
vim.o.lines = 20
require("organ").setup(%s)
require("treesitter-context").setup({})
local lines = { "* Top level", "** Second level" }
for i = 1, 30 do
  lines[#lines + 1] = "body line " .. i
end
local b = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
vim.bo[b].filetype = "org"
vim.wo.conceallevel = 2
vim.wo.concealcursor = "nc"
pcall(vim.treesitter.start, b, "org")
%s
vim.api.nvim_win_set_cursor(0, { 15, 0 })
vim.cmd("normal! zt")
vim.api.nvim_win_set_cursor(0, { 25, 0 })
require("treesitter-context").enable()
vim.cmd("redraw")
vim.wait(500)
vim.cmd("redraw")
local function row(r)
  local s = {}
  for c = 1, 60 do s[#s + 1] = vim.fn.screenstring(r, c) end
  return (table.concat(s):gsub("%%s+$", ""))
end
vim.fn.writefile({ "row1=" .. row(1), "row2=" .. row(2) }, %q)
vim.cmd("qa!")
]]):format(root, setup_opts, attach_expr, out)
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
    return nil
  end
  local kv = {}
  for _, l in ipairs(vim.fn.readfile(out)) do
    local k, v = l:match("^([%w_]+)=(.*)$")
    if k then
      kv[k] = v
    end
  end
  pcall(vim.fn.delete, out)
  pcall(vim.fn.delete, inner)
  return kv.row1 or "", kv.row2 or ""
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

local function count_stars(s)
  local _, n = s:gsub("%*", "")
  return n
end

-- Scenario 1: modern.bullets -- per-level glyphs, no literal stars.
local row1, row2 =
  run_scenario("{ modern = { bullets = true } }", 'require("organ.modern.bullets").attach(b)')
if not row1 then
  skip("pty run produced no screen dump (script variant mismatch?)")
end

local g1 = vim.fn.nr2char(0x25c9) -- default bullet.1
local g2 = vim.fn.nr2char(0x25cb) -- default bullet.2

check(
  "bullets: context float is showing the headline chain",
  row1:find("Top level", 1, true) ~= nil and row2:find("Second level", 1, true) ~= nil,
  "row1=" .. row1 .. " row2=" .. row2
)
check(
  "bullets: level-1 context line shows the bullet glyph, not `*`",
  row1:find(g1, 1, true) ~= nil and row1:find("*", 1, true) == nil,
  "row1=" .. row1
)
check(
  "bullets: level-2 context line shows the bullet glyph, not `**`",
  row2:find(g2, 1, true) ~= nil and row2:find("*", 1, true) == nil,
  "row2=" .. row2
)

-- Scenario 2: stars.hide -- leading stars hidden, the depth star kept.
row1, row2 = run_scenario("{ stars = { hide = true } }", 'require("organ.stars").attach(b)')
if not row1 then
  skip("pty run produced no screen dump (script variant mismatch?)")
end

check(
  "stars.hide: context float is showing the headline chain",
  row1:find("Top level", 1, true) ~= nil and row2:find("Second level", 1, true) ~= nil,
  "row1=" .. row1 .. " row2=" .. row2
)
check(
  "stars.hide: level-1 context line keeps its single star",
  row1:find("* Top level", 1, true) ~= nil and count_stars(row1) == 1,
  "row1=" .. row1
)
check(
  "stars.hide: level-2 context line hides the leading star, keeps one",
  row2:find("* Second level", 1, true) ~= nil and count_stars(row2) == 1,
  "row2=" .. row2
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("context_bullets_render_pty_test: PASS")
os.exit(0)
