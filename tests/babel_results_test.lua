-- organ.babel: the :results values that shape how output lands in the
-- buffer.  Every expectation below is what `emacs --batch -Q -l org`
-- (Emacs 30.2 / org 9.7.11) wrote for the same block.
--
-- Run via: nvim --headless -l tests/babel_results_test.lua

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

-- Runs `lines` and returns everything from the #+RESULTS: keyword down.
local function results_of(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  local ok, msg = babel.execute(b, 2)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  for i, l in ipairs(got) do
    if l:lower():match("^#%+results") then
      return vim.list_slice(got, i, #got), ok, msg
    end
  end
  return {}, ok, msg
end

local function same(label, got, want, msg)
  check(
    label,
    vim.deep_equal(got, want),
    "want " .. vim.inspect(want) .. " got " .. vim.inspect(got) .. (msg and (" msg=" .. msg) or "")
  )
end

same(
  ":results table",
  results_of({
    "#+begin_src sh :results output table",
    'echo "a b"; echo "c d"',
    "#+end_src",
  }),
  { "#+RESULTS:", "| a | b |", "| c | d |" }
)

same(
  ":results list",
  results_of({
    "#+begin_src sh :results output list",
    "echo one; echo two",
    "#+end_src",
  }),
  { "#+RESULTS:", ": - one", ": - two" }
)

same(
  ":results drawer",
  results_of({
    "#+begin_src sh :results output drawer",
    "echo hi",
    "#+end_src",
  }),
  { "#+RESULTS:", ":results:", "hi", ":end:" }
)

same(
  ":results html",
  results_of({
    "#+begin_src sh :results output html",
    "echo '<b>x</b>'",
    "#+end_src",
  }),
  { "#+RESULTS:", "#+begin_export html", "<b>x</b>", "#+end_export" }
)

same(
  ":results table collapses a single row, as Emacs does",
  results_of({
    "#+begin_src sh :results output table",
    'echo "a b"',
    "#+end_src",
  }),
  { "#+RESULTS:", ": a b" }
)

same(
  ":results latex",
  results_of({
    "#+begin_src sh :results output latex",
    "printf 'x_1\\n'",
    "#+end_src",
  }),
  { "#+RESULTS:", "#+begin_export latex", "x_1", "#+end_export" }
)

same(
  ":results code",
  results_of({
    "#+begin_src sh :results output code",
    "echo 'x=1'",
    "#+end_src",
  }),
  { "#+RESULTS:", "#+begin_src sh", "x=1", "#+end_src" }
)

same(
  ":wrap note",
  results_of({
    "#+begin_src sh :results output :wrap note",
    "echo wrapped",
    "#+end_src",
  }),
  { "#+RESULTS:", "#+begin_note", "wrapped", "#+end_note" }
)

same(
  ":results file",
  results_of({
    "#+begin_src sh :results file",
    "echo /tmp/x.png",
    "#+end_src",
  }),
  { "#+RESULTS:", "[[file:/tmp/x.png]]" }
)

-- `:results file :file PATH` writes the output to PATH and links to it,
-- rather than putting the output in the buffer.
do
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, dir .. "/f.org")
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "#+begin_src sh :results file :file o2.txt",
    "echo written-content",
    "#+end_src",
  })
  babel.execute(b, 2)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  same(":file writes the output and links to it", vim.list_slice(got, 5, #got), {
    "#+RESULTS:",
    "[[file:o2.txt]]",
  })
  check(
    ":file really wrote the file",
    table.concat(vim.fn.readfile(dir .. "/o2.txt"), "\n") == "written-content",
    vim.inspect(vim.fn.readfile(dir .. "/o2.txt"))
  )
  vim.fn.delete(dir, "rf")
end

-- append and prepend exist to keep earlier output.  Replacing it is data
-- loss, which is why these two come first in the fix order.
same(
  ":results append keeps the earlier output",
  results_of({
    "#+begin_src sh :results output append",
    "echo second",
    "#+end_src",
    "",
    "#+RESULTS:",
    ": first",
  }),
  { "#+RESULTS:", ": first", ": second" }
)

same(
  ":results prepend keeps the earlier output",
  results_of({
    "#+begin_src sh :results output prepend",
    "echo zeroth",
    "#+end_src",
    "",
    "#+RESULTS:",
    ": existing",
  }),
  { "#+RESULTS:", ": zeroth", ": existing" }
)

-- :results value asks for what the block returns, not what it prints.
-- Emacs gives `: 42` here and `: done` for the block that also prints.
if vim.fn.executable("python3") == 1 then
  same(
    ":results value returns the value",
    results_of({ "#+begin_src python :results value", "return 6*7", "#+end_src" }),
    { "#+RESULTS:", ": 42" }
  )
  same(
    ":results value discards what the block printed",
    results_of({
      "#+begin_src python :results value",
      'print("side")',
      'return "done"',
      "#+end_src",
    }),
    { "#+RESULTS:", ": done" }
  )
  same(
    "the default stays output collection, which is more useful than Emacs's None",
    results_of({ "#+begin_src python", 'print("default")', "#+end_src" }),
    { "#+RESULTS:", ": default" }
  )
else
  print("SKIP  python3 not on PATH (:results value)")
end

-- A later :results value only silences the earlier members of its own
-- exclusive group, so an inherited value survives a partial override.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "#+PROPERTY: header-args:sh :results output drawer",
    "",
    "#+begin_src sh :results table",
    'echo "a b"; echo "c d"',
    "#+end_src",
  })
  babel.execute(b, 4)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  same(
    ":results groups: table and drawer are in different groups, so both apply",
    vim.list_slice(got, 7, #got),
    { "#+RESULTS:", ":results:", "| a | b |", "| c | d |", ":end:" }
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_results_test: PASS")
