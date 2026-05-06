-- babel.tangle: :noweb yes expands <<name>> references; :mkdirp yes
-- creates parent dirs. Mirrors Emacs `org-babel-tangle`.
-- Run via: nvim --headless -l tests/babel_tangle_noweb_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
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

-- Source buffer with three blocks:
--   * a NAMED helper block (:name helper)
--   * a tangled block referencing <<helper>> with :noweb yes
--   * a tangled block targeting a NESTED dir (sub/dir/file) with :mkdirp yes
local out_path = tmp .. "/output.lua"
local nested_path = tmp .. "/sub/dir/nested.lua"

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(bufnr, tmp .. "/source.org")
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Sample",
  "#+begin_src lua :name helper",
  "local function shared() return 42 end",
  "#+end_src",
  "",
  "#+begin_src lua :tangle " .. out_path .. " :noweb yes",
  "<<helper>>",
  "print(shared())",
  "#+end_src",
  "",
  "#+begin_src lua :tangle " .. nested_path .. " :mkdirp yes",
  "print('nested')",
  "#+end_src",
})
vim.bo[bufnr].filetype = "org"

local results = babel.tangle(bufnr)

check("output.lua tangled OK", results[out_path] and results[out_path].ok)
check(
  "nested.lua tangled OK (mkdirp created the dir)",
  results[nested_path] and results[nested_path].ok
)

-- Verify noweb expansion happened: the tangled file contains the
-- helper's BODY, not a literal <<helper>> line.
local body = table.concat(vim.fn.readfile(out_path), "\n")
check(
  "noweb: tangled file contains the helper's body",
  body:find("local function shared() return 42 end", 1, true) ~= nil
)
check(
  "noweb: literal <<helper>> NOT present in tangled file",
  body:find("<<helper>>", 1, true) == nil,
  "got body:\n" .. body
)
check(
  "noweb: print() line still present after the expansion",
  body:find("print(shared())", 1, true) ~= nil
)

-- Verify mkdirp created the parent dirs.
check(
  "mkdirp: parent dir " .. tmp .. "/sub/dir created",
  vim.fn.isdirectory(tmp .. "/sub/dir") == 1
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("babel_tangle_noweb_test: PASS")
