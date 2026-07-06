-- organ.src_block_parsers(bufnr) reports the tree-sitter parser names a
-- buffer's #+begin_src blocks need, so a filetype-keyed installer can pick
-- up embedded languages (which are not buffer filetypes).  org-babel
-- spellings resolve to parser names; the list is deduped and sorted.
--
-- Run via: nvim --headless -l tests/src_block_parsers_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function langs(lines)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  return require("organ").src_block_parsers(b)
end

local got = langs({
  "* Notes",
  "#+begin_src python",
  "print(1)",
  "#+end_src",
  "#+begin_src sh", -- babel spelling -> bash
  "echo hi",
  "#+end_src",
  "#+BEGIN_SRC Lua", -- uppercase keyword + lang
  "print(2)",
  "#+end_src",
  "#+begin_src emacs-lisp", -- babel spelling -> elisp
  "(message x)",
  "#+end_src",
  "#+begin_src python :results output", -- dup + header args
  "pass",
  "#+end_src",
  "#+begin_src zig", -- unknown -> passthrough
  "const x = 1;",
  "#+end_src",
  "#+begin_src", -- bare, no language -> skipped
  "whatever",
  "#+end_src",
})

check("resolves python", vim.tbl_contains(got, "python"))
check("resolves sh -> bash", vim.tbl_contains(got, "bash"))
check("resolves uppercase Lua -> lua", vim.tbl_contains(got, "lua"))
check("resolves emacs-lisp -> elisp", vim.tbl_contains(got, "elisp"))
check("passes through unknown zig", vim.tbl_contains(got, "zig"))
check("deduped (python once)", vim.tbl_count(vim.tbl_filter(function(l)
  return l == "python"
end, got)) == 1)
check("bare #+begin_src contributes nothing", not vim.tbl_contains(got, ""))

-- Sorted.
local sorted = vim.deepcopy(got)
table.sort(sorted)
check("sorted", vim.deep_equal(got, sorted), vim.inspect(got))

-- Empty / no src blocks -> empty list.
check("no src blocks -> empty", #langs({ "* Just a heading", "body" }) == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("src_block_parsers_test: PASS")
os.exit(0)
