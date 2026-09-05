-- organ.babel: where a block's header arguments come from, and what a
-- block's name buys it.  The expected values were produced by
-- `emacs --batch -Q -l org` (Emacs 30.2 / org 9.7.11) on the same input.
--
-- Run via: nvim --headless -l tests/babel_headers_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  babel = { confirm_evaluate = false, timeout_ms = 15000 },
})

local babel = require("organ.babel")

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

local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- G. #+PROPERTY:, subtree properties, #+HEADER: and the block's own line,
-- in Emacs's precedence order.  Emacs on this exact buffer prints
-- `[plain][][sub][hdr][line]` for the first block and `[plain][prop]` for
-- the one in a subtree that does not override header-args:sh.
do
  local b = mkbuf({
    '#+PROPERTY: header-args:sh :var FROMPROP="prop"',
    '#+PROPERTY: header-args :var PLAIN="plain"',
    "",
    "* Sub",
    ":PROPERTIES:",
    ':header-args:sh: :var FROMSUB="sub"',
    ":END:",
    "",
    '#+HEADER: :var FROMHDR="hdr"',
    '#+begin_src sh :var FROMLINE="line"',
    'echo "[$PLAIN][$FROMPROP][$FROMSUB][$FROMHDR][$FROMLINE]"',
    "#+end_src",
    "",
    "* Sub2",
    "#+begin_src sh",
    'echo "[$PLAIN][$FROMPROP]"',
    "#+end_src",
  })
  babel.execute_buffer(b)
  local text = table.concat(lines_of(b), "\n")
  check(
    "G: property + subtree + #+HEADER: + block line",
    text:find(": [plain][][sub][hdr][line]", 1, true) ~= nil,
    text
  )
  check(
    "G: a subtree that overrides header-args:sh shadows the file property",
    text:find(": [plain][prop]", 1, true) ~= nil,
    text
  )
end

-- G (cont). #+HEADER: wins over the same key on the #+begin_src line;
-- Emacs prints `V=fromheader`.
do
  local b = mkbuf({
    '#+HEADER: :var V="fromheader"',
    '#+begin_src sh :var V="fromline"',
    'echo "V=$V"',
    "#+end_src",
  })
  babel.execute(b, 3)
  check(
    "G: #+HEADER: outranks the begin_src line",
    lines_of(b)[7] == ": V=fromheader",
    vim.inspect(lines_of(b))
  )
end

-- G (cont). Header args reach tangle too, not only execution.
do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local b = mkbuf({
    "#+PROPERTY: header-args:sh :tangle " .. dir .. "/from-property.sh",
    "",
    "#+begin_src sh",
    "echo tangled",
    "#+end_src",
  })
  babel.tangle(b)
  check(
    "G: :tangle inherited from #+PROPERTY:",
    vim.fn.filereadable(dir .. "/from-property.sh") == 1
  )
  vim.fn.delete(dir, "rf")
end

-- F. #+NAME: is org's way to name a block; organ's own `:name` header
-- argument keeps working beside it.
do
  local b = mkbuf({
    "#+NAME: keyword-named",
    "#+begin_src sh",
    "echo hi",
    "#+end_src",
    "",
    "#+begin_src sh :name arg-named",
    "echo hi",
    "#+end_src",
  })
  local blocks = babel.blocks(b)
  check(
    "F: #+NAME: names the block",
    blocks[1] and blocks[1].name == "keyword-named",
    vim.inspect(blocks[1])
  )
  check(
    "F: :name still names the block",
    blocks[2] and blocks[2].name == "arg-named",
    vim.inspect(blocks[2])
  )
end

-- F (cont). A named block owns `#+RESULTS: <name>` wherever it sits;
-- Emacs updates that keyword in place and inserts nothing after the block.
do
  local b = mkbuf({
    "* Top",
    "#+NAME: g",
    "#+begin_src sh",
    "echo fresh",
    "#+end_src",
    "",
    "Some prose.",
    "",
    "#+RESULTS: g",
    ": stale",
  })
  babel.execute(b, 4)
  local got = lines_of(b)
  check("F: the named results block is updated in place", got[10] == ": fresh", vim.inspect(got))
  check(
    "F: no duplicate results after #+END_SRC",
    got[6] == "" and got[7] == "Some prose.",
    vim.inspect(got)
  )
  check("F: the buffer did not grow", #got == 10, vim.inspect(got))
end

do
  local b = mkbuf({ "#+NAME: g", "#+begin_src sh", "echo one", "#+end_src" })
  babel.execute(b, 3)
  check(
    "F: a fresh named result carries its name",
    lines_of(b)[6] == "#+RESULTS: g",
    vim.inspect(lines_of(b))
  )
end

-- I. `:var v=NAME` naming another block substitutes that block's result.
-- Emacs prints `: got 99`.
do
  local b = mkbuf({
    "#+NAME: producer",
    "#+begin_src sh",
    "echo 99",
    "#+end_src",
    "",
    "#+begin_src sh :var v=producer",
    'echo "got $v"',
    "#+end_src",
  })
  babel.execute(b, 7)
  local text = table.concat(lines_of(b), "\n")
  check("I: :var resolves a block reference", text:find(": got 99", 1, true) ~= nil, text)
end

do
  local b = mkbuf({
    "#+NAME: producer",
    "#+begin_src sh",
    "echo unused",
    "#+end_src",
    "",
    "#+RESULTS: producer",
    ": 42",
    "",
    "#+begin_src sh :var v=producer",
    'echo "got $v"',
    "#+end_src",
  })
  babel.execute(b, 10)
  local text = table.concat(lines_of(b), "\n")
  check(
    "I: an existing #+RESULTS: is reused rather than re-run",
    text:find(": got 42", 1, true) ~= nil,
    text
  )
end

do
  -- organ keeps binding a bare word that names nothing as a literal, where
  -- Emacs raises "Reference not found".  Dropping that would remove the
  -- documented `:var KEY=VALUE` flat-string form.
  local b = mkbuf({ "#+begin_src sh :var y=hello", 'echo "$y"', "#+end_src" })
  babel.execute(b, 2)
  check(
    "I: an unmatched bare word stays a literal",
    lines_of(b)[6] == ": hello",
    vim.inspect(lines_of(b))
  )
end

do
  -- Non-shell languages cannot see the environment, so vars arrive as
  -- assignments in the body.
  if vim.fn.executable("python3") == 1 then
    local b = mkbuf({ "#+begin_src python :var n=7", "print(n * 2)", "#+end_src" })
    babel.execute(b, 2)
    check("I: python gets a real binding", lines_of(b)[6] == ": 77", vim.inspect(lines_of(b)))
  else
    print("SKIP  python3 not on PATH (:var binding)")
  end
end

-- M. `:cache yes` keys the result by a hash of the body and header args,
-- and skips the run while that hash still matches.
do
  local b = mkbuf({ "#+begin_src sh :cache yes", "echo cached", "#+end_src" })
  local _, msg1 = babel.execute(b, 2)
  local got = lines_of(b)
  check(
    "M: :cache writes a hashed results keyword",
    (got[5] or ""):match("^#%+RESULTS%[%x+%]:$") ~= nil,
    vim.inspect(got)
  )
  check("M: the first run really ran", (msg1 or ""):find("ran ", 1, true) ~= nil, tostring(msg1))
  local _, msg2 = babel.execute(b, 2)
  check(
    "M: the second run is served from the cache",
    (msg2 or ""):find("cached", 1, true) ~= nil,
    tostring(msg2)
  )
  vim.api.nvim_buf_set_lines(b, 1, 2, false, { "echo changed" })
  local _, msg3 = babel.execute(b, 2)
  check(
    "M: editing the body misses the cache",
    (msg3 or ""):find("ran ", 1, true) ~= nil,
    tostring(msg3)
  )
  check(
    "M: the refreshed result is the new output",
    lines_of(b)[6] == ": changed",
    vim.inspect(lines_of(b))
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_headers_test: PASS")
