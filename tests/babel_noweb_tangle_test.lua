-- organ.babel: noweb expansion (at tangle AND at evaluation) plus the
-- tangle-time header args that decide what the produced file looks like.
-- The expectations come from `emacs --batch -Q -l org` (Emacs 30.2 /
-- org 9.7.11) run on the same buffers.
--
-- Run via: nvim --headless -l tests/babel_noweb_tangle_test.lua

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

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function mkbuf(lines, name)
  local b = vim.api.nvim_create_buf(false, true)
  if name then
    vim.api.nvim_buf_set_name(b, name)
  end
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

-- J. Expansion is recursive, keeps the reference line's indentation on
-- every expanded line, and substitutes references that sit inside a line.
-- Emacs tangles this to:
--   def f():
--       print("inner")
--   x = "print("inner") inline"
--   f()
do
  local out = tmp .. "/nw.py"
  local b = mkbuf({
    "#+NAME: inner",
    "#+begin_src python",
    'print("inner")',
    "#+end_src",
    "",
    "#+NAME: outer",
    "#+begin_src python :noweb yes",
    "def f():",
    "    <<inner>>",
    "#+end_src",
    "",
    "#+begin_src python :noweb yes :tangle " .. out,
    "<<outer>>",
    'x = "<<inner>> inline"',
    "f()",
    "#+end_src",
  }, tmp .. "/nw.org")
  babel.tangle(b)
  local got = read(out)
  check("J: references expand recursively", got:find("def f():", 1, true) ~= nil, got)
  check(
    "J: an indented reference keeps its indentation",
    got:find('\n    print("inner")', 1, true) ~= nil,
    got
  )
  check(
    "J: an inline reference is substituted in place",
    got:find('x = "print("inner") inline"', 1, true) ~= nil,
    got
  )
  check("J: no literal reference survives", got:find("<<", 1, true) == nil, got)
end

-- J (cont). noweb applies at evaluation, not only at tangle.
do
  if vim.fn.executable("sh") == 1 then
    local b = mkbuf({
      "#+NAME: greet",
      "#+begin_src sh",
      "echo hello",
      "#+end_src",
      "",
      "#+begin_src sh :noweb yes",
      "<<greet>>",
      "#+end_src",
    })
    babel.execute(b, 7)
    local got = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    check("J: noweb expands before evaluation", got:find(": hello", 1, true) ~= nil, got)
  end
end

-- J (cont). :noweb eval expands at evaluation only; :noweb tangle at
-- tangle only (org-babel-noweb-p).
do
  local out = tmp .. "/ctx.txt"
  local b = mkbuf({
    "#+NAME: piece",
    "#+begin_src sh",
    "echo piece",
    "#+end_src",
    "",
    "#+begin_src sh :noweb tangle :tangle " .. out,
    'echo "<<piece>>"',
    "#+end_src",
  }, tmp .. "/ctx.org")
  babel.tangle(b)
  check(
    "J: :noweb tangle expands at tangle",
    read(out):find('echo "echo piece"', 1, true) ~= nil,
    read(out)
  )
  if vim.fn.executable("sh") == 1 then
    babel.execute(b, 7)
    local got = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    check("J: :noweb tangle does not expand at eval", got:find(": <<piece>>", 1, true) ~= nil, got)
  end
end

-- J (cont). A self-referential block completes instead of recursing until
-- the stack dies -- organ's behaviour, deliberately kept.  Bounded by wall
-- clock so a regression fails instead of hanging the suite.
do
  local out = tmp .. "/cycle.txt"
  local b = mkbuf({
    "#+NAME: loop",
    "#+begin_src sh :noweb yes :tangle " .. out,
    "echo before",
    "<<loop>>",
    "echo after",
    "#+end_src",
  }, tmp .. "/cycle.org")
  local started = vim.uv.hrtime()
  babel.tangle(b)
  local elapsed = (vim.uv.hrtime() - started) / 1e6
  check("J: a noweb cycle terminates", elapsed < 5000, ("%.0fms"):format(elapsed))
  local got = read(out)
  check("J: the cycle stops at the repeated reference", got:find("<<loop>>", 1, true) ~= nil, got)
  check("J: the surrounding body still tangles", got:find("echo after", 1, true) ~= nil, got)
end

-- K. :shebang writes the interpreter line AND makes the file executable
-- (Emacs produces mode 0755), so the tangled script can actually run.
do
  local out = tmp .. "/sb.sh"
  local b = mkbuf({
    "#+begin_src sh :tangle " .. out .. ' :shebang "#!/bin/sh"',
    "echo one",
    "#+end_src",
  }, tmp .. "/sb.org")
  babel.tangle(b)
  local got = read(out)
  check("K: the shebang is the first line", got:match("^#!/bin/sh\n") ~= nil, vim.inspect(got))
  local mode = vim.uv.fs_stat(out).mode % 512
  check("K: the tangled script is executable", mode == tonumber("755", 8), ("%o"):format(mode))
end

-- K (cont). :comments link brackets each block with a link back to it;
-- :padline no drops the blank line between blocks.
do
  local out = tmp .. "/cm.py"
  local b = mkbuf({
    "* My Heading",
    "#+NAME: nb",
    "#+begin_src python :tangle " .. out .. " :comments link",
    "x = 1",
    "#+end_src",
    "",
    "#+begin_src python :tangle " .. out .. " :padline no",
    "y = 2",
    "#+end_src",
  }, tmp .. "/cm.org")
  babel.tangle(b)
  local got = read(out)
  check(
    "K: :comments link opens with a link to the named block",
    got:find("# [[file:cm.org::nb][nb]]", 1, true) ~= nil,
    got
  )
  check("K: :comments link closes the block", got:find("# nb ends here", 1, true) ~= nil, got)
  check(
    "K: :padline no drops the separating blank line",
    got:find("ends here\ny = 2", 1, true) ~= nil,
    got
  )
end

do
  local out = tmp .. "/anon.py"
  local b = mkbuf({
    "* My Heading",
    "#+begin_src python :tangle " .. out .. " :comments link",
    "a = 1",
    "#+end_src",
  }, tmp .. "/anon.org")
  babel.tangle(b)
  local got = read(out)
  check(
    "K: an unnamed block links to its heading",
    got:find("# [[file:anon.org::*My Heading][My Heading:1]]", 1, true) ~= nil,
    got
  )
end

-- K (cont). Bodies are written at their own indentation, not the org
-- file's: Emacs strips the deepest common indent before tangling.
do
  local out = tmp .. "/ind.py"
  local b = mkbuf({
    "* H",
    "  #+begin_src python :tangle " .. out,
    "  def f():",
    "      return 1",
    "  #+end_src",
  }, tmp .. "/ind.org")
  babel.tangle(b)
  check(
    "K: the common indent is stripped",
    read(out) == "def f():\n    return 1",
    vim.inspect(read(out))
  )
end

-- Blocks sharing a destination are separated by one blank line by default.
do
  local out = tmp .. "/pad.sh"
  local b = mkbuf({
    "#+begin_src sh :tangle " .. out,
    "echo a",
    "#+end_src",
    "#+begin_src sh :tangle " .. out,
    "echo b",
    "#+end_src",
  }, tmp .. "/pad.org")
  babel.tangle(b)
  check("K: padline defaults to yes", read(out) == "echo a\n\necho b", vim.inspect(read(out)))
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_noweb_tangle_test: PASS")
