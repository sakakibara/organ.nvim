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

-- 6. Header values keep ":" inside quotes; surrounding quotes are stripped.
do
  local _, args =
    babel.parse_header('#+begin_src sh :var url="http://x.y/z" :dir "/tmp/a b" :noweb yes')
  assert(args.vars.url == "http://x.y/z", "quoted var: " .. tostring(args.vars.url))
  assert(args.dir == "/tmp/a b", "quoted dir: " .. tostring(args.dir))
  assert(args.noweb == "yes", "noweb: " .. tostring(args.noweb))
  assert(args['//x.y/z"'] == nil, "no bogus key from the URL")
  local _, a2 = babel.parse_header("#+begin_src sh :var x=42 :results output raw")
  assert(a2.vars.x == "42", "plain var: " .. tostring(a2.vars.x))
  assert(a2.results == "output raw", "results words: " .. tostring(a2.results))
end

-- 7. Cursor on the #+end_src line still belongs to the block.
do
  local sb = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(
    sb,
    0,
    -1,
    false,
    { "#+begin_src sh", "echo hi", "#+end_src", "after" }
  )
  local blk = babel.find_block(sb, 3)
  assert(blk and blk.end_line == 3, "end_src line should resolve to its block")
  assert(babel.find_block(sb, 4) == nil, "line after end_src is not a block")
end

-- 8. Results headers: lowercase, hashed, and named all count.
do
  for _, header in ipairs({ "#+results:", "#+RESULTS[abc123]:", "#+RESULTS: foo" }) do
    local sb = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(
      sb,
      0,
      -1,
      false,
      { "#+begin_src sh", "echo hi", "#+end_src", "", header, ": old" }
    )
    local s, e = babel.find_results(sb, 3)
    assert(s == 5 and e == 6, header .. " -> " .. tostring(s) .. "," .. tostring(e))
  end
end

-- 9. Results extent covers tables, lists, and blocks; a paragraph is not a result.
do
  local cases = {
    { { "| a | b |", "| 1 | 2 |", "#+TBLFM: $2=1", "", "After." }, 7 },
    { { "- a", "- b", "", "After." }, 6 },
    { { "old para", "After." }, 4 },
    { { "", "After." }, 4 },
    { { "[[file:x.png]]", "After." }, 5 },
    { { "#+begin_src org", "* x", "#+end_src", "After." }, 7 },
    { { ":results:", "old", ":end:", "After." }, 7 },
  }
  for _, c in ipairs(cases) do
    local sb = vim.api.nvim_create_buf(false, true)
    local lines = { "#+begin_src sh", "echo hi", "#+end_src", "#+RESULTS:" }
    vim.list_extend(lines, c[1])
    vim.api.nvim_buf_set_lines(sb, 0, -1, false, lines)
    local s, e = babel.find_results(sb, 3)
    assert(s == 4 and e == c[2], vim.inspect(c[1]) .. " -> " .. tostring(s) .. "," .. tostring(e))
  end
end

-- 10. :tangle yes -> <org basename>.<lang ext> next to the org file.
do
  local sb = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(sb, tmp .. "/notes.org")
  vim.api.nvim_buf_set_lines(sb, 0, -1, false, {
    "#+begin_src python :tangle yes",
    "print(1)",
    "#+end_src",
    "#+begin_src sh :tangle yes",
    "echo 1",
    "#+end_src",
  })
  local r = babel.tangle(sb)
  local py = vim.fn.resolve(tmp .. "/notes.py")
  local sh = vim.fn.resolve(tmp .. "/notes.sh")
  assert(r[py] and r[py].ok, "tangle yes python -> notes.py; got " .. vim.inspect(r))
  assert(r[sh] and r[sh].ok, "tangle yes sh -> notes.sh; got " .. vim.inspect(r))
  assert(vim.fn.filereadable(tmp .. "/yes") == 0, "no file literally named yes")
end

vim.fn.delete(tmp, "rf")
io.write("babel parse + tangle ok\n")
os.exit(0)
