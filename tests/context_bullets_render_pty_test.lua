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
-- star treatment: per-level glyphs under modern.bullets, leading stars
-- hidden (depth star kept) under stars.hide, and -- because the float
-- copies 'conceallevel' from the parent window only at creation -- that a
-- treatment toggled on AFTER the float exists still renders (the bridge
-- must sync the float's conceallevel).
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

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Run one pty nvim: organ setup, org buffer, `pre` (conceal options +
-- attach), scroll until the context float exists, `after_float`
-- (scenario-specific runtime mutation), then dump the two float rows.
-- A missing dump is a hard FAIL, not a skip: the pty itself is known
-- good (checked above), so no dump means the inner nvim crashed --
-- likely in the very code under test.
local function run_scenario(name, setup_opts, pre, after_float)
  local out = vim.fn.tempname() .. ".txt"
  local inner = vim.fn.tempname() .. ".lua"
  local log = vim.fn.tempname() .. ".log"

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
pcall(vim.treesitter.start, b, "org")
%s
vim.api.nvim_win_set_cursor(0, { 15, 0 })
vim.cmd("normal! zt")
vim.api.nvim_win_set_cursor(0, { 25, 0 })
require("treesitter-context").enable()
vim.cmd("redraw")
-- The context update is throttled + scheduled; poll for the float instead
-- of sleeping a fixed interval (slow runners need longer than any fixed
-- guess, fast ones shouldn't pay for it).
local function float_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      return w
    end
  end
end
vim.wait(5000, function()
  return float_win() ~= nil
end, 50)
%s
vim.cmd("redraw")
local function row(r)
  local s = {}
  for c = 1, 60 do s[#s + 1] = vim.fn.screenstring(r, c) end
  return (table.concat(s):gsub("%%s+$", ""))
end
vim.fn.writefile({ "row1=" .. row(1), "row2=" .. row(2) }, %q)
vim.cmd("qa!")
]]):format(root, setup_opts, pre, after_float, out)
  vim.fn.writefile(vim.split(prog, "\n"), inner)

  local nvim = vim.v.progpath
  local cmd = ("%s -u NONE --noplugin -S %s"):format(
    vim.fn.shellescape(nvim),
    vim.fn.shellescape(inner)
  )
  local sys = (vim.uv or vim.loop).os_uname().sysname
  local invocation
  if sys == "Darwin" then
    invocation = ("script -q /dev/null %s >%s 2>&1"):format(cmd, vim.fn.shellescape(log))
  else
    invocation = ("script -qec %s /dev/null >%s 2>&1"):format(
      vim.fn.shellescape(cmd),
      vim.fn.shellescape(log)
    )
  end
  os.execute(invocation)

  if vim.fn.filereadable(out) ~= 1 then
    local tail = {}
    if vim.fn.filereadable(log) == 1 then
      local all = vim.fn.readfile(log)
      for i = math.max(1, #all - 10), #all do
        tail[#tail + 1] = all[i]
      end
    end
    check(
      name .. ": inner nvim produced a screen dump",
      false,
      "inner output tail:\n     " .. table.concat(tail, "\n     ")
    )
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
  pcall(vim.fn.delete, log)
  return kv.row1 or "", kv.row2 or ""
end

local function count_stars(s)
  local _, n = s:gsub("%*", "")
  return n
end

local g1 = vim.fn.nr2char(0x25c9) -- default bullet.1
local g2 = vim.fn.nr2char(0x25cb) -- default bullet.2

-- Scenario 1: modern.bullets -- per-level glyphs, no literal stars.
local row1, row2 = run_scenario(
  "bullets",
  "{ modern = { bullets = true } }",
  [[vim.wo.conceallevel = 2
vim.wo.concealcursor = "nc"
require("organ.modern.bullets").attach(b)]],
  ""
)
if row1 then
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
end

-- Scenario 2: stars.hide -- leading stars hidden, the depth star kept.
row1, row2 = run_scenario(
  "stars.hide",
  "{ stars = { hide = true } }",
  [[vim.wo.conceallevel = 2
vim.wo.concealcursor = "nc"
require("organ.stars").attach(b)]],
  ""
)
if row1 then
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
end

-- Scenario 3: runtime toggle. The float is created while no treatment is
-- on and the window's conceallevel is 0, so the float is born with
-- conceallevel 0; treesitter-context never refreshes it. Toggling
-- stars.hide on afterwards must still take effect in the float (the
-- bridge syncs the float's conceallevel to the parent's).
row1, row2 = run_scenario(
  "toggle",
  "{}",
  "",
  [[require("organ.stars").toggle(b)
vim.cmd("redraw")
local fw = float_win()
vim.wait(2000, function()
  return fw ~= nil and vim.wo[fw].conceallevel == 2
end, 50)]]
)
if row1 then
  check(
    "toggle: context float is showing the headline chain",
    row1:find("Top level", 1, true) ~= nil and row2:find("Second level", 1, true) ~= nil,
    "row1=" .. row1 .. " row2=" .. row2
  )
  check(
    "toggle: stars.hide enabled after the float exists still hides in it",
    row2:find("* Second level", 1, true) ~= nil and count_stars(row2) == 1,
    "row2=" .. row2
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("context_bullets_render_pty_test: PASS")
os.exit(0)
