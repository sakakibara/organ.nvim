-- Regression: a grammar the build hook failed to install must not leave
-- org buffers silently unhighlighted for good.  Opening an org buffer
-- while a grammar is missing starts one background install per session;
-- success refreshes highlighting on the open org buffers, failure gives
-- one WARN naming the log, and present grammars trigger nothing.
--
-- vim.system is faked: git succeeds without touching the network, and
-- make either "builds" by copying the developer's real parsers into the
-- build dir or exits 69 the way an unaccepted Xcode license makes it.
--
-- A tree-sitter language stays registered once loaded, so each scenario
-- runs in its own child nvim, selected by ORGAN_RETRY_CASE.
--
-- Run via: nvim --headless -l tests/grammar_retry_test.lua

local root = vim.fn.getcwd()

local case = os.getenv("ORGAN_RETRY_CASE")
if not case then
  local failed = {}
  for _, c in ipairs({
    "present",
    "success",
    "inline",
    "failure",
    "partial",
    "busy",
    "broken",
    "unloadable",
    "hook",
    "inline_stuck",
    "locked",
    "stale_lock",
    "reload",
    "hang",
    "inline_garbage",
    "inline_broken",
    "rebuild_wait",
    "eperm",
  }) do
    local res = vim
      .system({ vim.v.progpath, "--headless", "-l", "tests/grammar_retry_test.lua" }, {
        env = { ORGAN_RETRY_CASE = c },
        text = true,
      })
      :wait(60000)
    io.write(res.stdout or "")
    io.stderr:write(res.stderr or "")
    if res.code ~= 0 then
      failed[#failed + 1] = c
    end
  end
  if #failed > 0 then
    io.stderr:write("grammar retry FAILED: " .. table.concat(failed, ", ") .. "\n")
    os.exit(1)
  end
  io.write("grammar retry ok\n")
  os.exit(0)
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
vim.env.XDG_DATA_HOME = sandbox
vim.env.ORGAN_DB_PATH = sandbox .. "/organ.db"
local parser_dir = vim.fn.stdpath("data") .. "/organ/parser"
assert(parser_dir:find(sandbox, 1, true), "sandbox not in effect: " .. parser_dir)

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/tests/deps/tablature.nvim")
vim.opt.runtimepath:prepend(root .. "/tests/deps/narrow.nvim")

local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = msg, level = level }
end

local make_mode = "ok"
local makes = 0
local untimed = {}
local plat = require("organ.grammar_install")._platform_triple()

local function fake_result(cmd, opts)
  if cmd[1] == "make" then
    makes = makes + 1
    if make_mode == "fail" or (make_mode == "fail_inline" and opts.cwd:match("%-inline$")) then
      return {
        code = 69,
        stdout = "",
        stderr = "You have not agreed to the Xcode license agreements.",
      }
    end
    local name = opts.cwd:match("%-inline$") and "org_inline.so" or "org.so"
    local out = opts.cwd .. "/build/" .. plat
    vim.fn.mkdir(out, "p")
    if make_mode == "garbage" or (make_mode == "garbage_inline" and name == "org_inline.so") then
      vim.fn.writefile({ "not a shared object" }, out .. "/" .. name)
    else
      assert(vim.uv.fs_copyfile(real_parser .. "/" .. name, out .. "/" .. name))
    end
    return { code = 0, stdout = "", stderr = "" }
  end
  if cmd[1] == "git" and cmd[2] == "clone" then
    vim.fn.mkdir(cmd[#cmd] .. "/.git", "p")
  end
  if cmd[1] == "git" and cmd[4] == "rev-parse" then
    return { code = 0, stdout = "deadbeef\n", stderr = "" }
  end
  return { code = 0, stdout = "", stderr = "" }
end

local real_system = vim.system
vim.system = function(cmd, opts, cb)
  if cmd[1] ~= "git" and cmd[1] ~= "make" and cmd[1] ~= "codesign" then
    return real_system(cmd, opts, cb)
  end
  if not (opts and opts.timeout) then
    untimed[#untimed + 1] = table.concat(cmd, " ")
  end
  if make_mode == "hang" and cmd[2] == "clone" then
    return { wait = function() end, kill = function() end }
  end
  local res = fake_result(cmd, opts or {})
  if cb then
    -- From a luv callback, the fast context the real vim.system uses.
    local t = assert(vim.uv.new_timer())
    t:start(10, 0, function()
      t:close()
      cb(res)
    end)
  end
  return {
    wait = function()
      return res
    end,
    kill = function() end,
  }
end

vim.cmd("runtime plugin/organ.lua")
require("organ").setup({ org_dir = sandbox })
vim.cmd("filetype plugin on")
vim.wait(50)

local n_file = 0
local function open_org()
  n_file = n_file + 1
  local path = ("%s/f%d.org"):format(sandbox, n_file)
  vim.fn.writefile({ "* TODO heading *bold*", "body with [[x][a link]]" }, path)
  vim.cmd("edit " .. path)
  return vim.api.nvim_get_current_buf()
end

local function highlighted(buf)
  return vim.treesitter.highlighter.active[buf] ~= nil
end

local function injected(buf)
  local parser = vim.treesitter.get_parser(buf, "org")
  parser:parse(true)
  return parser:children().org_inline ~= nil
end

local function install_real(files)
  vim.fn.mkdir(parser_dir, "p")
  for _, f in ipairs(files) do
    assert(vim.uv.fs_copyfile(real_parser .. "/" .. f, parser_dir .. "/" .. f))
  end
end

local function of_level(level)
  local out = {}
  for _, n in ipairs(notes) do
    if n.level == level then
      out[#out + 1] = n
    end
  end
  return out
end

if case == "present" then
  install_real({ "org.so", "org_inline.so" })
  local buf = open_org()
  vim.wait(100)
  assert(highlighted(buf), "present grammars must highlight on open")
  assert(makes == 0, "present grammars must not trigger an install")
  assert(#notes == 0, "present grammars must not notify, got: " .. vim.inspect(notes))
elseif case == "success" then
  local b1 = open_org()
  assert(makes == 0, "install must not run synchronously on the UI thread")
  local b2 = open_org()
  assert(
    vim.wait(5000, function()
      return highlighted(b1) and highlighted(b2)
    end, 10),
    "successful retry must start tree-sitter on every open org buffer, notes: "
      .. vim.inspect(notes)
  )
  assert(makes == 2, "one install (two grammars) expected, got " .. makes .. " make runs")
  assert(#of_level(vim.log.levels.WARN) == 0, "success must not warn: " .. vim.inspect(notes))
  assert(#of_level(vim.log.levels.ERROR) == 0, "success must not error: " .. vim.inspect(notes))
  assert(#of_level(vim.log.levels.INFO) == 2, "expected start + done INFO: " .. vim.inspect(notes))
  -- Loaded up front: a first dlopen inside the highlighter's async parse
  -- can overrun 'redrawtime' and leave the buffer unpainted.
  assert(vim._ts_has_language("org_inline"), "org_inline must load before any parse")
  assert(injected(b1), "the inline grammar must be injected after the install")
  assert(#untimed == 0, "every install command must be time-bounded: " .. vim.inspect(untimed))
  -- Missing again later in the session: the retry is spent.
  vim.fn.delete(parser_dir, "rf")
  notes = {}
  assert(require("organ.grammar_install").ensure(), "ensure must report the missing grammars")
  vim.wait(200)
  assert(makes == 2, "only one automatic retry per session, got " .. makes .. " make runs")
  assert(#notes == 0, "a spent retry must stay quiet: " .. vim.inspect(notes))
elseif case == "inline" then
  -- org.so alone highlights the buffer, so only the missing-file check
  -- notices that emphasis, links and timestamps have no grammar.
  install_real({ "org.so" })
  local buf = open_org()
  assert(highlighted(buf), "org.so alone still highlights")
  assert(not injected(buf), "precondition: no inline grammar yet")
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.INFO) == 2
    end, 10),
    "missing org_inline.so must trigger the retry, notes: " .. vim.inspect(notes)
  )
  assert(notes[1].msg:find("org_inline.so missing", 1, true), "names the missing grammar")
  assert(highlighted(buf), "the buffer stays highlighted")
  assert(injected(buf), "the open buffer picks up the inline grammar without a restart")
  assert(#of_level(vim.log.levels.WARN) == 0, "no restart prompt: " .. vim.inspect(notes))
elseif case == "inline_stuck" then
  -- If Neovim ever keeps the missing injected parser cached, the buffer
  -- cannot recover, and saying so beats leaving inline markup plain.
  collectgarbage("stop")
  install_real({ "org.so" })
  local buf = open_org()
  assert(not injected(buf), "precondition: no inline grammar yet")
  local real_collect = collectgarbage
  _G.collectgarbage = function(opt)
    if opt == nil or opt == "collect" then
      return 0
    end
    return real_collect(opt)
  end
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.INFO) == 2
    end, 10),
    "missing org_inline.so must trigger the retry, notes: " .. vim.inspect(notes)
  )
  _G.collectgarbage = real_collect
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "expected one restart prompt, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("restart Neovim", 1, true), warns[1].msg)
elseif case == "locked" then
  -- Another live Neovim is building into the same clones: wait for it
  -- instead of running git clean under its make.
  local lock = vim.fn.stdpath("data") .. "/organ/install.lock"
  vim.fn.mkdir(vim.fn.fnamemodify(lock, ":h"), "p")
  vim.fn.writefile({ tostring(vim.uv.os_getppid()) }, lock)
  local buf = open_org()
  vim.wait(300)
  assert(makes == 0, "must not build while another Neovim holds the lock")
  local ok, err = require("organ.grammar_install").install()
  assert(
    ok == false and err == "install already running",
    "sync install refuses: " .. tostring(err)
  )
  -- The other Neovim finishes.
  install_real({ "org.so", "org_inline.so" })
  vim.fn.delete(lock)
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "the waiting install must pick up the other Neovim's build, notes: " .. vim.inspect(notes)
  )
  assert(makes == 0, "nothing left to build, got " .. makes .. " make runs")
  assert(notes[#notes].msg:find("another Neovim", 1, true), vim.inspect(notes))
  assert(vim.fn.filereadable(lock) == 0, "the lock is released")
elseif case == "stale_lock" then
  -- A lock left by a Neovim that died mid-build does not block.
  local lock = vim.fn.stdpath("data") .. "/organ/install.lock"
  vim.fn.mkdir(vim.fn.fnamemodify(lock, ":h"), "p")
  local exited = vim.system({ "true" })
  local dead = exited.pid
  exited:wait()
  vim.fn.writefile({ tostring(dead) }, lock)
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "a stale lock must not block the install, notes: " .. vim.inspect(notes)
  )
  assert(makes == 2, "one install expected, got " .. makes .. " make runs")
  assert(vim.fn.filereadable(lock) == 0, "the lock is released")
elseif case == "reload" then
  -- Rebuilding a grammar this session already loaded cannot take effect
  -- until a restart, and the summary says so.
  install_real({ "org.so", "org_inline.so" })
  local buf = open_org()
  assert(highlighted(buf), "precondition: highlighted")
  -- The language stays loaded with no org buffer left.
  vim.cmd("bwipeout " .. buf)
  local gi = require("organ.grammar_install")
  assert(gi.install(), "the rebuild succeeds")
  assert(
    vim.fn.filereadable(vim.fn.stdpath("data") .. "/organ/install.lock") == 0,
    "a sync install releases the lock"
  )
  assert(#notes == 1, vim.inspect(notes))
  assert(notes[1].msg:find("restart Neovim", 1, true), notes[1].msg)
  -- :Org install_grammars takes the background path.
  notes = {}
  vim.cmd("Org install_grammars")
  assert(
    vim.wait(5000, function()
      return #notes == 2
    end, 10),
    vim.inspect(notes)
  )
  assert(notes[2].msg:find("restart Neovim", 1, true), notes[2].msg)
elseif case == "hang" then
  -- A command whose result never arrives (a grandchild holding the pipes)
  -- must not hold the install lock for the rest of the session.
  local gi = require("organ.grammar_install")
  gi._timeout_ms, gi._grace_ms = 100, 100
  make_mode = "hang"
  open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.WARN) > 0
    end, 10),
    "a hung command must time out, notes: " .. vim.inspect(notes)
  )
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1 and warns[1].msg:find("timed out", 1, true), vim.inspect(warns))
  local lock = vim.fn.stdpath("data") .. "/organ/install.lock"
  assert(vim.fn.filereadable(lock) == 0, "the lock is released")
elseif case == "partial" then
  -- The inline build failing after org.so built: org.so is still placed,
  -- so the buffer gets block highlighting, and the failure warns once.
  make_mode = "fail_inline"
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.WARN) > 0
    end, 10),
    "inline failure must warn, notes: " .. vim.inspect(notes)
  )
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "exactly one WARN, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("tree-sitter-organ-inline build failed", 1, true), warns[1].msg)
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "org.so placed by the partial install must highlight the buffer"
  )
elseif case == "busy" then
  -- The build hook (synchronous install) must not race a background one
  -- over the same clones.
  local buf = open_org()
  vim.wait(20, function()
    return makes > 0
  end, 1)
  local ok, err = require("organ.grammar_install").install()
  assert(
    ok == false and err == "install already running",
    "sync install must refuse: " .. tostring(err)
  )
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1 and warns[1].msg:find("still running", 1, true), vim.inspect(warns))
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "the background install must still finish, notes: " .. vim.inspect(notes)
  )
  assert(makes == 2, "only the background install builds, got " .. makes .. " make runs")
elseif case == "broken" then
  -- Present but unloadable (built for another arch, say): no install, and
  -- one fallback warning however many buffers open.
  vim.fn.mkdir(parser_dir, "p")
  for _, f in ipairs({ "org.so", "org_inline.so" }) do
    vim.fn.writefile({ "not a shared object" }, parser_dir .. "/" .. f)
  end
  open_org()
  open_org()
  vim.wait(200)
  assert(makes == 0, "present grammars must not trigger an install")
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "fallback must warn once per session, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find(":Org install_grammars", 1, true), "names the rebuild command")
elseif case == "unloadable" then
  -- Built and installed, but not loadable: the install reports success,
  -- so the failure to highlight must warn on its own, once.
  make_mode = "garbage"
  local buf = open_org()
  open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.INFO) == 2
    end, 10),
    "the install must finish, notes: " .. vim.inspect(notes)
  )
  assert(
    #of_level(vim.log.levels.WARN) == 1,
    "the open buffers' failure must warn: " .. vim.inspect(notes)
  )
  open_org()
  vim.wait(200)
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "an unloadable build must warn once, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find(":Org install_grammars", 1, true), "names the rebuild command")
  assert(not highlighted(buf), "precondition: the parser did not load")
elseif case == "hook" then
  -- A build hook that failed this session already warned; opening an org
  -- buffer right after must not rerun the same build and warn again.
  make_mode = "fail"
  local ok = require("organ.grammar_install").install()
  assert(ok == false, "the hook's install must fail")
  assert(#of_level(vim.log.levels.WARN) == 1, "the hook warns once: " .. vim.inspect(notes))
  open_org()
  vim.wait(200)
  assert(makes == 1, "no automatic retry after a failed install, got " .. makes .. " make runs")
  assert(#notes == 1, "nothing more to say: " .. vim.inspect(notes))
elseif case == "inline_garbage" then
  -- org_inline built but unloadable: a restart would not help, so say
  -- what is wrong instead.
  install_real({ "org.so" })
  make_mode = "garbage_inline"
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.WARN) > 0
    end, 10),
    "must warn, notes: " .. vim.inspect(notes)
  )
  vim.wait(100)
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "one warning, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("org_inline.so failed to load", 1, true), warns[1].msg)
  assert(highlighted(buf), "org.so still highlights")
elseif case == "inline_broken" then
  -- Present but unloadable org_inline at open time: org.so highlights, so
  -- only this check explains the plain inline markup.
  install_real({ "org.so" })
  vim.fn.writefile({ "not a shared object" }, parser_dir .. "/org_inline.so")
  local buf = open_org()
  open_org()
  vim.wait(200)
  assert(makes == 0, "present grammars must not trigger an install")
  assert(highlighted(buf), "org.so still highlights")
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "one warning per session, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("org_inline.so failed to load", 1, true), warns[1].msg)
elseif case == "rebuild_wait" then
  -- An explicit rebuild that waited on another Neovim still builds: the
  -- other install may have failed and left the old parsers in place.
  install_real({ "org.so", "org_inline.so" })
  local lock = vim.fn.stdpath("data") .. "/organ/install.lock"
  vim.fn.writefile({ tostring(vim.uv.os_getppid()) }, lock)
  vim.cmd("Org install_grammars")
  vim.wait(300)
  assert(makes == 0, "must not build while the lock is held")
  vim.fn.delete(lock)
  assert(
    vim.wait(5000, function()
      return makes == 2
    end, 10),
    "the rebuild must run after the wait, notes: " .. vim.inspect(notes)
  )
  assert(
    vim.wait(5000, function()
      return notes[#notes].msg:find("grammars installed (", 1, true) ~= nil
    end, 10),
    vim.inspect(notes)
  )
elseif case == "eperm" then
  -- pid 1 is alive but not this user's: not a Neovim that could hold the
  -- lock, so the lock is stale.
  local lock = vim.fn.stdpath("data") .. "/organ/install.lock"
  vim.fn.mkdir(vim.fn.fnamemodify(lock, ":h"), "p")
  vim.fn.writefile({ "1" }, lock)
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "another user's pid must not block, notes: " .. vim.inspect(notes)
  )
  assert(makes == 2, "one install expected, got " .. makes .. " make runs")
elseif case == "failure" then
  make_mode = "fail"
  local b1 = open_org()
  open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.WARN) > 0
    end, 10),
    "failed retry must warn, notes: " .. vim.inspect(notes)
  )
  open_org()
  vim.wait(200)
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "failure must warn exactly once, got: " .. vim.inspect(warns))
  local w = warns[1].msg
  local log = vim.fn.stdpath("data") .. "/organ/grammar-install.log"
  assert(
    w:find("tree-sitter-organ build failed: make exited 69", 1, true),
    "names grammar + first error line: " .. w
  )
  assert(not w:find("Xcode", 1, true), "only the first error line belongs in the warning: " .. w)
  assert(w:find(log, 1, true), "names the log path: " .. w)
  assert(w:find(":Org install_grammars", 1, true), "names the retry command: " .. w)
  assert(#of_level(vim.log.levels.ERROR) == 0, "failure reports at WARN: " .. vim.inspect(notes))
  assert(makes == 1, "one retry, stopping at the first grammar, got " .. makes .. " make runs")
  assert(not highlighted(b1), "failed install must leave the buffer unhighlighted")
  local logged = table.concat(vim.fn.readfile(log), "\n")
  assert(
    logged:find("ERROR: tree-sitter-organ build failed: make exited 69", 1, true),
    "log keeps the ERROR line"
  )
  assert(logged:find("Xcode license", 1, true), "log keeps the full error")
else
  error("unknown ORGAN_RETRY_CASE " .. case)
end

io.write("grammar retry " .. case .. " ok\n")
os.exit(0)
