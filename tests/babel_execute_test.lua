-- organ.babel.execute: header args reach the subprocess and #+RESULTS:
-- blocks are inserted, replaced, and formatted the way Emacs org-babel
-- does (ob-core.el: org-babel-insert-result, org-babel-result-end,
-- org-babel-examplify-region). Uses `sh` only.
-- Run via: nvim --headless -l tests/babel_execute_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  babel = { confirm_evaluate = false },
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

local function run(lines, cursor)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local ok, msg = babel.execute(b, cursor or 2)
  return ok, msg, vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

local function same(label, got, want, msg)
  check(
    label,
    vim.deep_equal(got, want),
    "want "
      .. vim.inspect(want)
      .. " got "
      .. vim.inspect(got)
      .. (msg and (" msg=" .. tostring(msg)) or "")
  )
end

if vim.fn.executable("sh") ~= 1 then
  print("SKIP  sh not on PATH")
  os.exit(0)
end

-- :var reaches the process environment.
do
  local ok, msg, got = run({ "#+begin_src sh :var X=42", 'echo "X=$X"', "#+end_src" })
  check(":var execute succeeds", ok, tostring(msg))
  same(
    ":var X=42 -> X=42",
    got,
    { "#+begin_src sh :var X=42", 'echo "X=$X"', "#+end_src", "", "#+RESULTS:", ": X=42" }
  )
end

-- :var values with ":" and quotes.
do
  local _, _, got = run({ '#+begin_src sh :var url="http://x.y/z"', 'echo "$url"', "#+end_src" })
  same(':var url="http://x.y/z"', got[6], ": http://x.y/z")
end

-- :results output raw inserts lines verbatim.
do
  local _, _, got = run({ "#+begin_src sh :results output raw", "echo '* hi'", "#+end_src" })
  same(
    ":results output raw",
    got,
    { "#+begin_src sh :results output raw", "echo '* hi'", "#+end_src", "", "#+RESULTS:", "* hi" }
  )
end

-- :results silent / none evaluate without touching the buffer.
for _, word in ipairs({ "silent", "none" }) do
  local src =
    { "#+begin_src sh :results " .. word, "echo hi", "#+end_src", "", "#+RESULTS:", ": old" }
  local ok, msg, got = run(src)
  check(":results " .. word .. " succeeds", ok, tostring(msg))
  same(":results " .. word .. " leaves buffer alone", got, src)
end

-- Existing results are replaced in place, keeping their header line.
do
  local cases = {
    { "lowercase header", { "#+results:", ": old" }, { "#+results:", ": new" } },
    { "hashed header", { "#+RESULTS[abc123]:", ": old" }, { "#+RESULTS[abc123]:", ": new" } },
    { "table result", { "#+RESULTS:", "| a | b |", "| 1 | 2 |" }, { "#+RESULTS:", ": new" } },
    { "list result", { "#+RESULTS:", "- a", "- b" }, { "#+RESULTS:", ": new" } },
    {
      "example result",
      { "#+RESULTS:", "#+begin_example", "old", "#+end_example" },
      { "#+RESULTS:", ": new" },
    },
    { "drawer result", { "#+RESULTS:", ":results:", "old", ":end:" }, { "#+RESULTS:", ": new" } },
    { "header only", { "#+RESULTS:" }, { "#+RESULTS:", ": new" } },
  }
  for _, c in ipairs(cases) do
    local lines = { "#+begin_src sh", "echo new", "#+end_src", "" }
    vim.list_extend(lines, c[2])
    lines[#lines + 1] = "After."
    local want = { "#+begin_src sh", "echo new", "#+end_src", "" }
    vim.list_extend(want, c[3])
    want[#want + 1] = "After."
    local _, msg, got = run(lines)
    same("replace " .. c[1], got, want, msg)
  end
end

-- A paragraph after the header is not a result and stays put.
do
  local _, msg, got =
    run({ "#+begin_src sh", "echo new", "#+end_src", "", "#+RESULTS:", "old para" })
  same(
    "paragraph after header kept",
    got,
    { "#+begin_src sh", "echo new", "#+end_src", "", "#+RESULTS:", ": new", "old para" },
    msg
  )
end

-- Cursor on #+end_src executes the block.
do
  local ok, msg, got = run({ "#+begin_src sh", "echo new", "#+end_src" }, 3)
  check("cursor on #+end_src executes", ok, tostring(msg))
  same("cursor on #+end_src inserts results", { got[5], got[6] }, { "#+RESULTS:", ": new" })
end

-- Output shorter than org-babel-min-lines-for-block-output (10) uses `: ` lines.
do
  local _, _, got = run({ "#+begin_src sh :results output", "echo a; echo b", "#+end_src" })
  same("two lines -> two `: ` lines", { got[5], got[6], got[7] }, { "#+RESULTS:", ": a", ": b" })
  local _, _, nine = run({ "#+begin_src sh :results output", "seq 1 9", "#+end_src" })
  same(
    "nine lines -> `: ` lines",
    { nine[5], nine[6], nine[14], nine[15] },
    { "#+RESULTS:", ": 1", ": 9", nil }
  )
  local _, _, ten = run({ "#+begin_src sh :results output", "seq 1 10", "#+end_src" })
  same(
    "ten lines -> example block",
    { ten[5], ten[6], ten[7], ten[16], ten[17] },
    { "#+RESULTS:", "#+begin_example", "1", "10", "#+end_example" }
  )
end

-- Empty output leaves only the header.
do
  local _, _, got = run({ "#+begin_src sh :results output", "true", "#+end_src" })
  same(
    "empty output -> header only",
    got,
    { "#+begin_src sh :results output", "true", "#+end_src", "", "#+RESULTS:" }
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_execute_test: PASS")
