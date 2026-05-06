-- organ.babel: parse_header, find_block, find_results, tangle. Skips actual
-- subprocess execution to keep the test deterministic + fast.
-- Run via: nvim --headless -l tests/babel_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local babel = require("organ.babel")

-- 1. Header parser.
do
  local lang, args =
    babel.parse_header("#+BEGIN_SRC python :results value :var x=42 :var y=hello :tangle out.py")
  assert(lang == "python", "lang: " .. lang)
  assert(args.results == "value", "results: " .. tostring(args.results))
  assert(args.tangle == "out.py", "tangle: " .. tostring(args.tangle))
  assert(args.vars.x == "42", "var x")
  assert(args.vars.y == "hello", "var y")
end

-- 2. find_block detects begin/end pair around cursor.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local fixture = tmp .. "/x.org"
local fh = assert(io.open(fixture, "w"))
fh:write([[* H
Some prose.

#+BEGIN_SRC sh :results output
echo hello
echo world
#+END_SRC

After.

#+BEGIN_SRC lua :tangle script.lua
print("from tangle")
#+END_SRC
]])
fh:close()
local b = vim.fn.bufadd(fixture)
vim.fn.bufload(b)

local block = babel.find_block(b, 5) -- cursor on `echo hello`
assert(block, "find_block hit")
assert(block.lang == "sh", "lang: " .. block.lang)
assert(#block.body_lines == 2, "body lines: " .. #block.body_lines)
assert(block.body_lines[1] == "echo hello", "body[1]: " .. block.body_lines[1])
assert(block.args.results == "output", "args.results: " .. tostring(block.args.results))

-- Cursor outside any block returns nil.
assert(babel.find_block(b, 2) == nil, "prose line should not be a block")

-- 3. find_results: inject a results block manually and detect it.
vim.api.nvim_buf_set_lines(
  b,
  block.end_line,
  block.end_line,
  false,
  { "", "#+RESULTS:", ": hello world" }
)
local rs, re = babel.find_results(b, block.end_line)
assert(rs and re, "find_results should locate the new block")
assert(re - rs == 1, "single-line results: 2 lines (header + `: ` line); got " .. (re - rs + 1))

-- 4. Wrapped results block (#+begin_example/#+end_example).
vim.api.nvim_buf_set_lines(
  b,
  block.end_line + 1,
  block.end_line + 3,
  false,
  { "#+RESULTS:", "#+begin_example", "line1", "line2", "#+end_example" }
)
local rs2, re2 = babel.find_results(b, block.end_line)
assert(rs2 and re2, "find_results should locate wrapped block")
local count = re2 - rs2 + 1
assert(count == 5, "wrapped block: 5 lines (header + begin + 2 body + end); got " .. count)

-- 5. Tangle: write all :tangle blocks to their destination files.
local results = babel.tangle(b)
-- On macOS `vim.fn.tempname()` returns paths under /var/..., but
-- tangle resolves through `:p` which canonicalizes to /private/var/...
-- — match the canonical form so the lookup hits regardless of OS.
local script_path = vim.fn.resolve(tmp .. "/script.lua")
assert(results[script_path], "expected tangle to script.lua; got: " .. vim.inspect(results))
assert(results[script_path].ok, "tangle failed: " .. tostring(results[script_path].error))
local fd = assert(io.open(script_path, "r"))
local content = fd:read("*a")
fd:close()
assert(
  content:find('print("from tangle")', 1, true),
  "tangled file content unexpected:\n" .. content
)

vim.fn.delete(tmp, "rf")
io.write("babel parse + tangle ok\n")
os.exit(0)
