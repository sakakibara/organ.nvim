-- Behavioral test: execute a python src block via :Org babel execute.
--
-- Disables the confirm prompt (allow_languages = {"python"}), opens a
-- file with a python source block, places the cursor inside, fires
-- the dispatcher, and verifies #+RESULTS: lines appear with the
-- expected stdout.  Skipped (PASS) if python3 is not on PATH so CI
-- without python won't fail noisily.
--
-- Exercises:
--   :Org babel execute -> organ.babel.commands.babel_execute
--   organ.babel.execute (find_block, runner dispatch, format_results)
--   organ.babel.languages.python (subprocess invocation)
--   #+RESULTS: insertion below #+end_src
--
-- Run via: nvim --headless -l tests/behavioral/babel_execute_python_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Skip cleanly if python3 is unavailable.
if vim.fn.executable("python3") ~= 1 then
  print("SKIP  python3 not on PATH; skipping babel-python execute test")
  print("babel_execute_python_test: PASS (skipped)")
  return
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/notes.org"
vim.fn.writefile({
  "#+TITLE: Notes",
  "",
  "* Block",
  "#+begin_src python",
  "print(2 + 3)",
  "#+end_src",
}, fixture)

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  babel = { allow_languages = { "python" } },
})

vim.cmd("filetype plugin on")
vim.cmd("edit " .. fixture)
local buf = vim.api.nvim_get_current_buf()
vim.wait(500, function()
  return vim.bo[buf].filetype == "org"
end)

-- Cursor inside the python block (line 5 -- print(2 + 3)).
vim.api.nvim_win_set_cursor(0, { 5, 0 })

-- Pre-state: no #+RESULTS line in the buffer.
do
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local has_results = false
  for _, l in ipairs(lines) do
    if l:match("^%s*#%+RESULTS:") then
      has_results = true
    end
  end
  check("pre-state: no #+RESULTS yet", not has_results)
end

vim.cmd("Org babel execute")

-- Post-state: #+RESULTS: appears, followed by ": 5" output line.
do
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local results_line = nil
  for i, l in ipairs(lines) do
    if l:match("^%s*#%+RESULTS:") then
      results_line = i
      break
    end
  end
  check("post: #+RESULTS line inserted", results_line ~= nil, table.concat(lines, "|"))
  if results_line then
    -- Output is rendered as ": 5" on the line following #+RESULTS.
    local out_line = lines[results_line + 1]
    check(
      "post: result line shows '5'",
      out_line and out_line:match("5") ~= nil,
      "got: " .. tostring(out_line)
    )
  end
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_execute_python_test: PASS")
