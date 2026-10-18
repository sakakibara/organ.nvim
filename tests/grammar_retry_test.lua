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
    "hang_sync",
    "interrupt",
    "inline_garbage",
    "inline_broken",
    "rebuild_wait",
    "foreign",
    "override",
    "override_missing",
    "foreign_loaded",
    "inline_large",
    "inline_stuck_split",
    "foreign_ftfirst",
    "symlink",
    "indexer_registers",
    "rtp_registers",
    "empty_path",
    "foreign_sync",
    "foreign_late",
    "relative_path",
    "literal_path",
    "foreign_unloadable",
    "foreign_unloadable_sync",
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

-- Another plugin's "org", registered by explicit path right after
-- org.so is placed: at its codesign on macOS, else at the first command
-- after placement.  Any later and organ's own indexer may register org
-- first.  The inline grammar stands in for the other plugin's.
local late_added = false
local function add_late_foreign()
  if case ~= "foreign_late" or late_added then
    return
  end
  late_added = true
  assert(not vim._ts_has_language("org"), "premise: org not registered yet")
  assert(pcall(vim.treesitter.language.add, "org", {
    path = real_parser .. "/org_inline.so",
    symbol_name = "org_inline",
  }))
end

local function fake_result(cmd, opts)
  if cmd[1] == "codesign" and cmd[#cmd]:match("/org%.so$") then
    add_late_foreign()
  end
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
      return { code = 0, stdout = "", stderr = "" }
    end
    -- In a child process, as the real build is: copying on the UI thread
    -- would stall it in a way no real install does.
    return { cp = { "cp", real_parser .. "/" .. name, out .. "/" .. name } }
  end
  if cmd[1] == "git" and cmd[2] == "init" then
    vim.fn.mkdir(cmd[#cmd] .. "/.git", "p")
  end
  if cmd[1] == "git" and cmd[4] == "rev-parse" and cmd[5] == "--verify" then
    local pin = require("organ.grammar_install").pins()[vim.fs.basename(cmd[3])]
    return { code = 0, stdout = pin .. "\n", stderr = "" }
  end
  if cmd[1] == "git" and cmd[4] == "rev-parse" then
    -- After the parsers are placed, before the install finishes.
    if case == "indexer_registers" then
      require("organ.indexer.extract").ensure_languages(require("organ").config.parser_path)
    elseif case == "rtp_registers" then
      assert(pcall(vim.treesitter.language.add, "org"))
    end
    add_late_foreign()
    return { code = 0, stdout = "deadbeef\n", stderr = "" }
  end
  return { code = 0, stdout = "", stderr = "" }
end

local real_system = vim.system
local real_codesign = false
vim.system = function(cmd, opts, cb)
  if cmd[1] == "codesign" and real_codesign then
    -- A fresh identifier makes the signature new to the system, so the
    -- first dlopen is as slow as after a real build.
    cmd = { "codesign", "--force", "--sign", "-", "-i", "organ" .. vim.uv.hrtime(), cmd[#cmd] }
    return real_system(cmd, opts, cb)
  end
  if cmd[1] ~= "git" and cmd[1] ~= "make" and cmd[1] ~= "codesign" then
    return real_system(cmd, opts, cb)
  end
  if not (opts and opts.timeout) then
    untimed[#untimed + 1] = table.concat(cmd, " ")
  end
  if make_mode == "hang" and cmd[2] == "init" then
    -- SystemObj:wait(t) on a process whose pipes never close: it waits t,
    -- kills, waits t again and returns nil.
    return {
      wait = function(_, t)
        vim.wait(2 * (t or 1e9), function()
          return false
        end)
      end,
      kill = function() end,
    }
  end
  local res = fake_result(cmd, opts or {})
  if res.cp then
    return real_system(res.cp, { timeout = opts.timeout }, cb)
  end
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
-- setup() after `filetype plugin on`, as with setup in a plugin/ file or
-- a plugin manager loading organ on the org filetype: ftplugin/org.lua
-- then runs before setup()'s own FileType handler.
local ft_first = case == "foreign_ftfirst"
if ft_first then
  vim.cmd("filetype plugin on")
end
local custom = sandbox .. "/custom/org.so"
local linked = sandbox .. "/linked/org.so"
-- A literal $, which an env-expanding reading would turn into $HOME.
local literal = sandbox .. "/$HOME/org.so"
if case == "relative_path" then
  vim.cmd.cd(sandbox)
end
if case == "symlink" then
  -- Another spelling of the install directory, through a symlink, on a
  -- machine where the parser directory does not exist yet.
  assert(vim.fn.isdirectory(parser_dir) == 0, "precondition: no parser dir yet")
  assert(vim.uv.fs_symlink(vim.fn.fnamemodify(parser_dir, ":h"), sandbox .. "/linked"))
  linked = sandbox .. "/linked/parser/org.so"
end
require("organ").setup({
  org_dir = sandbox,
  parser_path = (case == "override" or case == "override_missing") and custom
    or case == "symlink" and linked
    or case == "empty_path" and ""
    or case == "relative_path" and "custom/org.so"
    or case == "literal_path" and literal
    or nil,
})
if case == "relative_path" then
  vim.cmd.cd("/")
end
if not ft_first then
  vim.cmd("filetype plugin on")
end
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

-- Another Neovim's install, simulated by an flock on a second open file
-- description, which conflicts even within one process.
local ffi = require("ffi")
pcall(ffi.cdef, "int flock(int fd, int operation);")
local lock = vim.fn.stdpath("data") .. "/organ/install.lock"
local function hold_lock()
  vim.fn.mkdir(vim.fn.fnamemodify(lock, ":h"), "p")
  local fd = assert(vim.uv.fs_open(lock, "a+", 420))
  assert(ffi.C.flock(fd, 6) == 0, "could not take the lock")
  vim.uv.fs_ftruncate(fd, 0)
  vim.uv.fs_write(fd, tostring(vim.uv.os_getppid()))
  return fd
end
local function lock_free()
  local fd = vim.uv.fs_open(lock, "a+", 420)
  if not fd then
    return true
  end
  local free = ffi.C.flock(fd, 6) == 0
  vim.uv.fs_close(fd)
  return free
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
  vim.wait(300)
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
  vim.wait(2000, function()
    return #of_level(vim.log.levels.WARN) > 0
  end, 10)
  vim.wait(100)
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "expected one restart prompt, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("restart Neovim", 1, true), warns[1].msg)
elseif case == "inline_stuck_split" then
  -- The inline check covers every window showing the buffer, not just the
  -- first: here only the second window shows inline markup.
  collectgarbage("stop")
  install_real({ "org.so" })
  local lines = {}
  for i = 1, 199 do
    lines[i] = "plain words " .. i
  end
  -- Separate paragraphs, so the plain one holds no injection site.
  lines[200] = ""
  for i = 201, 260 do
    lines[i] = "some *bold* text " .. i
  end
  local path = sandbox .. "/split.org"
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. path)
  vim.cmd("vsplit")
  local wins = vim.fn.win_findbuf(vim.api.nvim_get_current_buf())
  vim.api.nvim_win_call(wins[1], function()
    vim.cmd("normal! gg")
  end)
  vim.api.nvim_win_call(wins[2], function()
    vim.cmd("normal! G")
  end)
  assert(vim.fn.line("w$", wins[1]) < 200, "precondition: first window shows only plain lines")
  assert(vim.fn.line("w0", wins[2]) > 200, "precondition: second window shows the markup")
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
    vim.inspect(notes)
  )
  vim.wait(2000, function()
    return #of_level(vim.log.levels.WARN) > 0
  end, 10)
  _G.collectgarbage = real_collect
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "expected one restart prompt, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("restart Neovim", 1, true), warns[1].msg)
elseif case == "locked" then
  -- Another live Neovim is building into the same clones: wait for it
  -- instead of running git clean under its make.
  local held = hold_lock()
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
  vim.uv.fs_close(held)
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "the waiting install must pick up the other Neovim's build, notes: " .. vim.inspect(notes)
  )
  assert(makes == 0, "nothing left to build, got " .. makes .. " make runs")
  assert(notes[#notes].msg:find("another Neovim", 1, true), vim.inspect(notes))
  assert(lock_free(), "the lock is released")
elseif case == "stale_lock" then
  -- A Neovim SIGKILLed mid-build leaves the lock file behind, but not
  -- the lock.
  vim.fn.mkdir(vim.fn.fnamemodify(lock, ":h"), "p")
  local script = sandbox .. "/holder.lua"
  vim.fn.writefile({
    'local ffi = require("ffi")',
    'ffi.cdef("int flock(int fd, int operation);")',
    ("local fd = vim.uv.fs_open(%q, 'a+', 420)"):format(lock),
    "assert(ffi.C.flock(fd, 6) == 0)",
    "vim.uv.fs_write(fd, tostring(vim.uv.os_getpid()))",
    'io.write("held\\n") io.flush()',
    "vim.uv.sleep(60000)",
  }, script)
  local held = false
  local proc = vim.system({ vim.v.progpath, "--headless", "-l", script }, {
    stdout = function(_, data)
      held = held or (data or ""):find("held", 1, true) ~= nil
    end,
  })
  assert(
    vim.wait(5000, function()
      return held
    end, 10),
    "holder did not take the lock"
  )
  assert(not lock_free(), "precondition: the holder has the lock")
  proc:kill(9)
  proc:wait()
  assert(vim.fn.filereadable(lock) == 1, "precondition: the lock file is left behind")
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "a stale lock must not block the install, notes: " .. vim.inspect(notes)
  )
  assert(makes == 2, "one install expected, got " .. makes .. " make runs")
  assert(lock_free(), "the lock is released")
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
  assert(lock_free(), "a sync install releases the lock")
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
  assert(lock_free(), "the lock is released")
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
elseif case == "foreign_unloadable_sync" then
  -- The same through the build hook's synchronous install.
  make_mode = "garbage"
  assert(pcall(vim.treesitter.language.add, "org", {
    path = real_parser .. "/org_inline.so",
    symbol_name = "org_inline",
  }))
  assert(require("organ.grammar_install").install(), "the install succeeds")
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "one warning, got: " .. vim.inspect(notes))
  assert(warns[1].msg:find("org.so failed to load", 1, true), warns[1].msg)
  assert(
    not warns[1].msg:find("organ_probe", 1, true),
    "names the language as org: " .. warns[1].msg
  )
elseif case == "foreign_unloadable" then
  -- organ's build will not load while another plugin's "org" is
  -- registered: a rebuild is what helps, not a restart.
  make_mode = "garbage"
  assert(pcall(vim.treesitter.language.add, "org", {
    path = real_parser .. "/org_inline.so",
    symbol_name = "org_inline",
  }))
  open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.INFO) == 2
    end, 10),
    "the install must finish, notes: " .. vim.inspect(notes)
  )
  vim.wait(100)
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "one warning, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("org.so failed to load", 1, true), warns[1].msg)
  assert(warns[1].msg:find(":Org install_grammars", 1, true), "names the rebuild command")
  assert(not warns[1].msg:find("restart Neovim", 1, true), warns[1].msg)
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
elseif case == "hang_sync" then
  -- The same through the build hook's synchronous install: bounded by the
  -- timeout plus grace, not twice that.
  local gi = require("organ.grammar_install")
  gi._timeout_ms, gi._grace_ms = 200, 100
  make_mode = "hang"
  local t0 = vim.uv.hrtime()
  local ok = gi.install()
  local ms = (vim.uv.hrtime() - t0) / 1e6
  assert(ok == false, "a hung command fails the install")
  assert(ms < 550, ("returned after %dms, bound is 300ms"):format(ms))
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1 and warns[1].msg:find("timed out", 1, true), vim.inspect(warns))
  assert(lock_free(), "the lock is released")
elseif case == "interrupt" then
  -- Ctrl-C during the build hook's wait stops the install and says so,
  -- rather than reporting a timeout.
  make_mode = "hang"
  vim.defer_fn(function()
    vim.api.nvim_input("<C-c>")
  end, 100)
  local ok = require("organ.grammar_install").install()
  assert(ok == false, "an interrupted install fails")
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1 and warns[1].msg:find("interrupted", 1, true), vim.inspect(warns))
  assert(lock_free(), "the lock is released")
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
  local held = hold_lock()
  vim.cmd("Org install_grammars")
  vim.wait(300)
  assert(makes == 0, "must not build while the lock is held")
  vim.uv.fs_close(held)
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
elseif case == "inline_large" then
  -- Rechecking a large buffer for the inline grammar must not freeze the
  -- UI: the longest gap between ticks of a 10ms timer stays small.
  install_real({ "org.so" })
  real_codesign = vim.fn.executable("codesign") == 1
  local lines = {}
  for i = 1, 20000 do
    lines[i] = ("- item %d with *bold* and [[x][a link]] and ~code~"):format(i)
  end
  local path = sandbox .. "/large.org"
  vim.fn.writefile(lines, path)
  -- The held lock parks the install until opening the buffer has settled,
  -- so only the install's own work is measured.
  local held = hold_lock()
  vim.cmd("edit " .. path)
  local buf = vim.api.nvim_get_current_buf()
  vim.wait(3000)
  local last, worst = vim.uv.hrtime(), 0
  local timer = assert(vim.uv.new_timer())
  timer:start(
    10,
    10,
    vim.schedule_wrap(function()
      local now = vim.uv.hrtime()
      worst = math.max(worst, (now - last) / 1e6)
      last = now
    end)
  )
  vim.uv.fs_close(held)
  assert(
    vim.wait(10000, function()
      return #of_level(vim.log.levels.INFO) == 3
    end, 10),
    vim.inspect(notes)
  )
  vim.wait(3000, function()
    return vim.treesitter.get_parser(buf, "org"):children().org_inline ~= nil
  end, 10)
  -- One more tick, so a stall at the very end is measured too.
  vim.wait(100)
  timer:close()
  io.write(("worst gap %dms\n"):format(worst))
  assert(worst < 250, ("the UI stalled for %dms"):format(worst))
  assert(#of_level(vim.log.levels.WARN) == 0, vim.inspect(notes))
elseif case == "foreign" then
  -- Another plugin's "org" parser on the runtimepath is not organ's
  -- grammar: it must not count as installed or be loaded.
  local site = vim.fn.stdpath("data") .. "/site/parser"
  vim.fn.mkdir(site, "p")
  for _, f in ipairs({ "org.so", "org_inline.so" }) do
    vim.fn.writefile({ "someone else's parser" }, site .. "/" .. f)
  end
  vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/site")
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "a foreign org.so must not stop the retry, notes: " .. vim.inspect(notes)
  )
  assert(makes == 2, "one install expected, got " .. makes .. " make runs")
  assert(injected(buf), "organ's inline grammar is injected")
  assert(#of_level(vim.log.levels.WARN) == 0, vim.inspect(notes))
elseif case == "override" then
  -- A parser_path the user builds: never built by organ, and loaded from
  -- there before anything can register "org" from the runtimepath, where
  -- a parser in the default dir would otherwise win.
  vim.fn.mkdir(vim.fn.fnamemodify(custom, ":h"), "p")
  for _, f in ipairs({ "org.so", "org_inline.so" }) do
    assert(
      vim.uv.fs_copyfile(real_parser .. "/" .. f, vim.fn.fnamemodify(custom, ":h") .. "/" .. f)
    )
  end
  install_real({ "org.so", "org_inline.so" })
  local registered
  local add = vim.treesitter.language.add
  vim.treesitter.language.add = function(lang, opts)
    local had = vim._ts_has_language(lang)
    local ok, res = pcall(add, lang, opts)
    if lang == "org" and ok and not had and not registered then
      registered = opts and opts.path or "runtimepath"
    end
    if not ok then
      error(res, 0)
    end
    return res
  end
  local buf = open_org()
  vim.wait(200)
  assert(makes == 0, "organ must not build a user-managed parser_path")
  assert(highlighted(buf), "the override must highlight, notes: " .. vim.inspect(notes))
  assert(registered == custom, "org registered from " .. tostring(registered))
  assert(injected(buf), "the inline grammar loads from beside the override")
  assert(#notes == 0, vim.inspect(notes))
elseif case == "override_missing" then
  -- A user-managed parser_path that is missing: no build, one warning.
  local buf = open_org()
  open_org()
  vim.wait(200)
  assert(makes == 0, "organ must not build a user-managed parser_path")
  assert(not highlighted(buf))
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "one warning, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find(custom, 1, true), "names the path: " .. warns[1].msg)
  assert(
    not warns[1].msg:find(":Org install_grammars", 1, true),
    "a rebuild organ cannot do is not offered: " .. warns[1].msg
  )
  -- Asked anyway, organ says why it will not build.
  notes = {}
  vim.cmd("Org install_grammars")
  vim.wait(200)
  assert(makes == 0, "nothing built for a user-managed parser_path")
  assert(
    #notes == 1 and notes[1].msg:find("outside organ's install directory", 1, true),
    vim.inspect(notes)
  )
elseif case == "foreign_ftfirst" then
  -- A copy of organ's grammar elsewhere on the runtimepath, picked up by
  -- folding after the install has started: the same grammar, so no
  -- restart is asked for.
  local site = sandbox .. "/other"
  vim.fn.mkdir(site .. "/parser", "p")
  assert(vim.uv.fs_copyfile(real_parser .. "/org.so", site .. "/parser/org.so"))
  vim.opt.runtimepath:append(site)
  local buf = open_org()
  assert(vim._ts_has_language("org"), "precondition: org registered from the runtimepath")
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.INFO) == 2
    end, 10),
    vim.inspect(notes)
  )
  vim.wait(100)
  assert(highlighted(buf), "highlighted, notes: " .. vim.inspect(notes))
  assert(#of_level(vim.log.levels.WARN) == 0, "no restart prompt: " .. vim.inspect(notes))
elseif case == "foreign_late" then
  -- Another plugin's "org" registered by explicit path after the parsers
  -- are placed, before the install finishes.
  open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.WARN) > 0
    end, 10),
    vim.inspect(notes)
  )
  vim.wait(100)
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "one warning, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("restart Neovim", 1, true), warns[1].msg)
  assert(late_added, "the foreign parser was registered")
elseif case == "relative_path" or case == "literal_path" then
  -- A relative parser_path names the directory setup() ran in, across a
  -- later :cd; a $ in it is part of the name.
  local want = case == "relative_path" and custom or literal
  vim.fn.mkdir(vim.fn.fnamemodify(want, ":h"), "p")
  for _, f in ipairs({ "org.so", "org_inline.so" }) do
    assert(vim.uv.fs_copyfile(real_parser .. "/" .. f, vim.fn.fnamemodify(want, ":h") .. "/" .. f))
  end
  local gi = require("organ.grammar_install")
  -- Through realpath: the temp dir is reached through a symlink on macOS.
  assert(
    vim.uv.fs_realpath(gi.path("org.so")) == vim.uv.fs_realpath(want),
    "loads from " .. gi.path("org.so")
  )
  local buf = open_org()
  vim.wait(200)
  assert(makes == 0, "organ must not build a user-managed parser_path")
  assert(highlighted(buf), "highlighted, notes: " .. vim.inspect(notes))
  assert(injected(buf), "the inline grammar loads from beside it")
  assert(#notes == 0, vim.inspect(notes))
elseif case == "indexer_registers" or case == "rtp_registers" then
  -- organ's own grammars registered mid-install, by the indexer or through
  -- the runtimepath once placed, are not a foreign parser.
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.INFO) == 2
    end, 10),
    vim.inspect(notes)
  )
  vim.wait(100)
  assert(highlighted(buf), "highlighted, notes: " .. vim.inspect(notes))
  assert(#of_level(vim.log.levels.WARN) == 0, "no restart prompt: " .. vim.inspect(notes))
elseif case == "empty_path" then
  -- An empty parser_path means the default, which organ builds.
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "the retry must run, notes: " .. vim.inspect(notes)
  )
  assert(makes == 2, "one install expected, got " .. makes)
  assert(
    pcall(require("organ.indexer.extract").ensure_languages, require("organ").config.parser_path),
    "the indexer reads an empty parser_path as the default too"
  )
elseif case == "symlink" then
  -- parser_path naming the install directory through a symlink is still
  -- organ's to build.
  local buf = open_org()
  assert(
    vim.wait(5000, function()
      return highlighted(buf)
    end, 10),
    "the retry must run, notes: " .. vim.inspect(notes)
  )
  assert(makes == 2, "one install expected, got " .. makes)
elseif case == "foreign_sync" then
  -- The same through the build hook's synchronous install.
  assert(pcall(vim.treesitter.language.add, "org", {
    path = real_parser .. "/org_inline.so",
    symbol_name = "org_inline",
  }))
  assert(require("organ.grammar_install").install(), "the install succeeds")
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "one warning, got: " .. vim.inspect(notes))
  assert(warns[1].msg:find("restart Neovim", 1, true), warns[1].msg)
elseif case == "foreign_loaded" then
  -- Another plugin's "org" registered before organ's grammar existed
  -- stays for the session; the install says a restart is needed instead
  -- of a rebuild that cannot help.  The inline grammar stands in for the
  -- foreign one.
  assert(pcall(vim.treesitter.language.add, "org", {
    path = real_parser .. "/org_inline.so",
    symbol_name = "org_inline",
  }))
  open_org()
  assert(
    vim.wait(5000, function()
      return #of_level(vim.log.levels.WARN) > 0
    end, 10),
    vim.inspect(notes)
  )
  vim.wait(100)
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "one warning, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("restart Neovim", 1, true), warns[1].msg)
  assert(makes == 2, "the install still runs, got " .. makes)
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
