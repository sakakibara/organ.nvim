-- organ.babel: the ways a src block can damage the document or wedge the
-- editor.  Every case below was checked against Emacs 30.2 / org 9.7.11
-- with `emacs --batch -Q -l org` before it was encoded here.
--
-- Run via: nvim --headless -l tests/babel_safety_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  babel = { confirm_evaluate = true, allow_languages = { "sh" } },
})

local babel = require("organ.babel")
local buf_config = require("organ.buf_config")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

if vim.fn.executable("sh") ~= 1 then
  print("SKIP  sh not on PATH")
  os.exit(0)
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

-- A. The confirmation gate must read the buffer whose block is running,
-- not whatever buffer happens to be current.  `sh` is allow-listed
-- globally; the target buffer withdraws that, so the block must be
-- refused even though the current buffer would have allowed it.
do
  local target = mkbuf({ "#+begin_src sh", "echo ran", "#+end_src" })
  buf_config.set(target, "babel.allow_languages", {})
  local current = mkbuf({ "* elsewhere" })
  vim.api.nvim_set_current_buf(current)
  local ok, msg = babel.execute(target, 2)
  check("A: gate reads the target buffer, not the current one", not ok, "msg=" .. tostring(msg))
  check("A: refused block wrote nothing", #vim.api.nvim_buf_get_lines(target, 0, -1, false) == 3)
end

-- Everything below runs blocks on purpose.
buf_config.set(0, "babel.confirm_evaluate", false)
require("organ").config.babel.confirm_evaluate = false

-- B. A #+begin_src inside #+BEGIN_EXAMPLE is documentation.  Emacs
-- executes nothing there and tangles nothing from it.
do
  local lines = {
    "* H",
    "#+BEGIN_EXAMPLE",
    "#+begin_src sh :tangle " .. vim.fn.tempname() .. ".sh",
    "echo in-example",
    "#+end_src",
    "#+END_EXAMPLE",
    "",
    "#+begin_src sh",
    "echo real",
    "#+end_src",
  }
  local b = mkbuf(lines)
  check("B: find_block returns nil inside an example block", babel.find_block(b, 4) == nil)
  local count = babel.execute_buffer(b)
  check("B: only the real block ran", count == 1, "count=" .. tostring(count))
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check(
    "B: the example block is untouched",
    vim.deep_equal(vim.list_slice(got, 1, 6), vim.list_slice(lines, 1, 6)),
    vim.inspect(got)
  )
  check("B: the real block got its results", got[13] == ": real", vim.inspect(got))
  local tangled = babel.tangle(b)
  check(
    "B: nothing tangled out of the example block",
    vim.tbl_isempty(tangled),
    vim.inspect(tangled)
  )
end

-- B (cont). A COMMENT subtree is excluded from tangling but its blocks
-- still evaluate on request -- both verified against Emacs.
do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local b = mkbuf({
    "* Real",
    "#+begin_src sh :tangle " .. dir .. "/real.sh",
    "echo real",
    "#+end_src",
    "* COMMENT Hidden",
    "#+begin_src sh :tangle " .. dir .. "/hidden.sh",
    "echo hidden",
    "#+end_src",
  })
  local tangled = babel.tangle(b)
  check("B: COMMENT subtree is not tangled", vim.fn.filereadable(dir .. "/hidden.sh") == 0)
  check(
    "B: the live subtree still tangles",
    vim.fn.filereadable(dir .. "/real.sh") == 1,
    vim.inspect(tangled)
  )
  local ok = babel.execute(b, 7)
  check("B: a block in a COMMENT subtree still evaluates", ok)
  vim.fn.delete(dir, "rf")
end

-- An unclosed #+begin_src is a paragraph to org, not a block: Emacs neither
-- executes nor tangles it.
do
  local out = vim.fn.tempname() .. ".sh"
  local b = mkbuf({ "#+begin_src sh :tangle " .. out, "echo unterminated" })
  check("B: an unclosed #+begin_src is not a block", babel.find_block(b, 2) == nil)
  check("B: nothing runs in it", select(1, babel.execute_buffer(b)) == 0)
  check("B: nothing tangles out of it", vim.tbl_isempty(babel.tangle(b)))
end

-- A src block inside #+begin_quote IS parsed by org and does run.
do
  local b =
    mkbuf({ "#+begin_quote", "#+begin_src sh", "echo in-quote", "#+end_src", "#+end_quote" })
  local ok = babel.execute(b, 3)
  local got = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  check(
    "B: a block inside a quote block still runs",
    ok and got:find(": in-quote", 1, true) ~= nil,
    got
  )
end

-- C. :dir must expand `~` and must report a missing directory instead of
-- throwing out of jobstart and abandoning the rest of the run.
do
  local b = mkbuf({ "#+begin_src sh :dir ~", "pwd", "#+end_src" })
  local ok = babel.execute(b, 2)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  check("C: :dir ~ runs", ok and got[6] == ": " .. vim.fn.expand("~"), vim.inspect(got))
end

do
  local b = mkbuf({
    "#+begin_src sh",
    "echo first",
    "#+end_src",
    "",
    "#+begin_src sh :dir /organ-no-such-dir",
    "pwd",
    "#+end_src",
    "",
    "#+begin_src sh",
    "echo last",
    "#+end_src",
  })
  local ran, errs = babel.execute_buffer(b)
  local got = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  check(
    "C: a bad :dir does not abort the buffer run",
    ran >= 2,
    "ran=" .. tostring(ran) .. " errors=" .. vim.inspect(errs)
  )
  check(
    "C: the blocks around it still ran",
    got:find(": first", 1, true) and got:find(": last", 1, true)
  )
  check(
    "C: the bad :dir is reported, not swallowed",
    got:find("not a directory", 1, true) ~= nil,
    got
  )
end

-- D. A session evaluation that times out must not leak its late output --
-- nor organ's sentinel -- into the next block's result.
do
  local sessions = require("organ.babel.sessions")
  local started = vim.uv.hrtime()
  local out1, err1 = sessions.eval("sh", "bleed", "sleep 1; echo late", 150)
  check("D: the slow block times out", out1 == nil and err1 and err1:find("timed out") ~= nil)
  local out2, err2 = sessions.eval("sh", "bleed", "echo mine", 5000)
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  check("D: the next block succeeds", err2 == nil, tostring(err2))
  check(
    "D: no abandoned output bleeds in",
    out2 and not out2:find("late", 1, true),
    vim.inspect(out2)
  )
  check(
    "D: no sentinel bleeds in",
    out2 and not out2:find("__ORG_BABEL_END_", 1, true),
    vim.inspect(out2)
  )
  check("D: drain is bounded", elapsed < 8000, ("%.0fms"):format(elapsed))
  sessions.stop_session("sh", "bleed")
end

-- E. A long-running block must not freeze nvim for a fixed minute and
-- must report the timeout instead of leaving a silent, empty #+RESULTS:.
do
  buf_config.set(0, "babel.timeout_ms", 400)
  local b = mkbuf({ "#+begin_src sh", "echo early; sleep 20", "#+end_src" })
  buf_config.set(b, "babel.timeout_ms", 400)
  buf_config.set(b, "babel.confirm_evaluate", false)
  local started = vim.uv.hrtime()
  local ok = babel.execute(b, 2)
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  local got = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  check("E: the block returns", ok)
  check("E: it honours babel.timeout_ms", elapsed < 10000, ("%.0fms"):format(elapsed))
  check("E: the timeout is reported", got:find("timed out", 1, true) ~= nil, got)
  check("E: output produced before the timeout survives", got:find("early", 1, true) ~= nil, got)
end

-- L. A sh session result must be the block's output, with no interactive
-- prompt, job-control notice or terminal escape.  Emacs gives `: one`.
do
  local sessions = require("organ.babel.sessions")
  local out = sessions.eval("sh", "clean", "echo one", 5000) or ""
  check("L: sh session output is clean", out:gsub("%s+$", "") == "one", vim.inspect(out))
  check("L: no job-control notice", not out:find("job control", 1, true), vim.inspect(out))
  check("L: no terminal escape", not out:find("\27", 1, true), vim.inspect(out))
  local bash = vim.fn.executable("bash") == 1 and sessions.eval("bash", "clean", "echo two", 5000)
  if bash then
    check("L: bash session output is clean", bash:gsub("%s+$", "") == "two", vim.inspect(bash))
  end
  sessions.stop_all()
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_safety_test: PASS")
