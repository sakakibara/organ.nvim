-- Real-redraw guard for the background grammar install: once it finishes,
-- an org buffer opened while the grammars were missing must ACTUALLY get
-- painted, not merely have a highlighter attached.  Runs nvim under a real
-- pty, lets the main loop redraw on its own, and reads the rendered cells.
--
-- git and make are faked (make copies the developer's real parsers);
-- codesign runs for real with a fresh identifier, so the first dlopen is
-- as slow as after a real build, and a short 'redrawtime' makes a parse
-- step that has to absorb that dlopen overrun it.
--
-- Skips gracefully when a usable pty `script` is unavailable.
--
-- Run via: nvim --headless -l tests/grammar_retry_render_pty_test.lua

local root = vim.fn.getcwd()

local function skip(why)
  print("(skipped: " .. why .. ")")
  print("grammar_retry_render_pty_test: SKIP")
  os.exit(0)
end

if vim.fn.executable("script") ~= 1 then
  skip("no `script` binary for a pty")
end

local real_parser = vim.fn.stdpath("data") .. "/organ/parser"
for _, f in ipairs({ "org.so", "org_inline.so" }) do
  if vim.fn.filereadable(real_parser .. "/" .. f) == 0 then
    io.stderr:write("ERROR: missing " .. real_parser .. "/" .. f .. "; run `make grammar` first\n")
    os.exit(2)
  end
end

local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")
local out = sandbox .. "/result.txt"
local inner = sandbox .. "/inner.lua"

local prog = ([==[
local root, sandbox, real_parser, out = %q, %q, %q, %q
vim.env.XDG_DATA_HOME = sandbox .. "/data"
vim.env.ORGAN_DB_PATH = sandbox .. "/organ.db"
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/tests/deps/tablature.nvim")
vim.opt.runtimepath:prepend(root .. "/tests/deps/narrow.nvim")
vim.o.columns = 40
vim.o.redrawtime = 150
vim.api.nvim_set_hl(0, "@org.todo.active", { fg = 0xff0000, bold = true })

local plat = require("organ.grammar_install")._platform_triple()
local real_system = vim.system
local function fake(cmd, opts)
  if cmd[1] == "make" then
    local name = opts.cwd:match("%%-inline$") and "org_inline.so" or "org.so"
    local dir = opts.cwd .. "/build/" .. plat
    vim.fn.mkdir(dir, "p")
    assert(vim.uv.fs_copyfile(real_parser .. "/" .. name, dir .. "/" .. name))
  elseif cmd[2] == "clone" then
    vim.fn.mkdir(cmd[#cmd] .. "/.git", "p")
  elseif cmd[4] == "rev-parse" then
    return { code = 0, stdout = "deadbeef\n", stderr = "" }
  end
  return { code = 0, stdout = "", stderr = "" }
end
vim.system = function(cmd, opts, cb)
  if cmd[1] == "codesign" then
    cmd = { "codesign", "--force", "--sign", "-", "-i", "organ" .. vim.uv.hrtime(), cmd[#cmd] }
    return real_system(cmd, opts, cb)
  end
  if cmd[1] ~= "git" and cmd[1] ~= "make" then
    return real_system(cmd, opts, cb)
  end
  local res = fake(cmd, opts or {})
  if cb then
    vim.defer_fn(function() cb(res) end, 10)
  end
  return { wait = function() return res end }
end

local done = false
vim.notify = function(msg)
  if msg:find("grammars installed", 1, true) then done = true end
end

vim.cmd("runtime plugin/organ.lua")
require("organ").setup({ org_dir = sandbox })
vim.cmd("filetype plugin on")
-- Off, so a cell can only be colored by tree-sitter.
vim.cmd("syntax off")
local path = sandbox .. "/a.org"
-- Inline markup makes the parse load org_inline for the injection.
vim.fn.writefile({ "* TODO heading *bold*", "plain body [[x][a link]]" }, path)
vim.cmd("edit " .. path)

-- Found on screen rather than assumed: the sign and fold columns shift
-- the text right.
local function attr_of(row, word)
  local line = ""
  for c = 1, vim.o.columns do
    line = line .. vim.fn.screenstring(row, c)
  end
  local col = line:find(word, 1, true)
  return col and vim.fn.screenattr(row, col) or -1
end
local function cells()
  return attr_of(1, "TODO"), attr_of(2, "plain"), attr_of(2, "a link")
end

local result = {}
local t0 = vim.uv.now()
local function poll()
  if done and not result.done_at then
    result.done_at = vim.uv.now()
  end
  -- Give the main loop time to redraw on its own after the install.
  if result.done_at and vim.uv.now() - result.done_at > 1500 then
    local todo, body, link = cells()
    result.active = vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] ~= nil
    vim.fn.writefile({
      "done=" .. tostring(done),
      "active=" .. tostring(result.active),
      "todo_attr=" .. todo,
      "body_attr=" .. body,
      "link_attr=" .. link,
    }, out)
    vim.cmd("qa!")
  elseif vim.uv.now() - t0 > 15000 then
    vim.fn.writefile({ "done=" .. tostring(done), "timeout=true" }, out)
    vim.cmd("qa!")
  else
    vim.defer_fn(poll, 50)
  end
end
vim.defer_fn(poll, 50)
]==]):format(root, sandbox, real_parser, out)
vim.fn.writefile(vim.split(prog, "\n"), inner)

local nvim = vim.v.progpath
local cmd = ("%s -u NONE -i NONE --noplugin -S %s"):format(
  vim.fn.shellescape(nvim),
  vim.fn.shellescape(inner)
)
local sys = (vim.uv or vim.loop).os_uname().sysname
local invocation
if sys == "Darwin" then
  invocation = ("script -q /dev/null %s </dev/null >%s 2>&1"):format(cmd, sandbox .. "/pty.log")
else
  invocation = ("script -qec %s /dev/null </dev/null >%s 2>&1"):format(
    vim.fn.shellescape(cmd),
    sandbox .. "/pty.log"
  )
end
-- Bounded: the inner nvim quits itself after 15s, the outer timeout is a
-- backstop against a wedged pty.
if vim.fn.executable("timeout") == 1 then
  invocation = "timeout 60 " .. invocation
end
-- stdin from /dev/null: `script` fails to set up the pty when its stdin
-- is a socket, as under some CI runners and agent shells.
os.execute(invocation)

if vim.fn.filereadable(out) ~= 1 then
  local log = table.concat(vim.fn.readfile(sandbox .. "/pty.log"), "\n")
  print("FAIL  the pty run produced no screen dump\n" .. log)
  vim.fn.delete(sandbox, "rf")
  os.exit(1)
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

local detail = vim.inspect(kv)
check("the background install finished", kv.done == "true" and kv.timeout == nil, detail)
check("tree-sitter is attached to the buffer", kv.active == "true", detail)
check(
  "the TODO keyword is painted differently from body text",
  kv.todo_attr ~= nil
    and kv.todo_attr ~= "-1"
    and kv.body_attr ~= "-1"
    and kv.todo_attr ~= kv.body_attr,
  detail
)
check(
  "the link, from the inline grammar, is painted differently from body text",
  kv.link_attr ~= nil and kv.link_attr ~= "-1" and kv.link_attr ~= kv.body_attr,
  detail
)

vim.fn.delete(sandbox, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("grammar_retry_render_pty_test: PASS")
os.exit(0)
