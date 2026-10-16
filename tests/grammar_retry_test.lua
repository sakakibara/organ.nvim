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
  for _, c in ipairs({ "present", "success", "inline", "failure", "partial", "busy", "broken" }) do
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
    assert(vim.uv.fs_copyfile(real_parser .. "/" .. name, out .. "/" .. name))
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
  local res = fake_result(cmd, opts or {})
  if cb then
    vim.defer_fn(function()
      cb(res)
    end, 10)
  end
  return {
    wait = function()
      return res
    end,
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
  -- Neovim memoizes the missing injected parser for the session, so the
  -- honest outcome is one prompt to restart.
  local warns = of_level(vim.log.levels.WARN)
  assert(#warns == 1, "expected one restart prompt, got: " .. vim.inspect(warns))
  assert(warns[1].msg:find("restart Neovim", 1, true), warns[1].msg)
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
