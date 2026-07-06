-- #+begin_src highlighting must inject the language named in the fence for
-- ANY installed parser, not a fixed list (queries/org/injections.scm uses a
-- dynamic @injection.language capture).  Also checks that organ registers
-- the org-babel spellings that differ from parser names (organ.ts_lang).
--
-- Uses parsers bundled with the sandbox nvim (lua, c, vimdoc,
-- markdown_inline); vimdoc / markdown_inline were NOT in the old hardcoded
-- list, so their injection proves the dynamic path.
--
-- Run via: nvim --headless -l tests/injection_dynamic_test.lua

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

local function injected(lang, body)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].filetype = "org"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#+begin_src " .. lang, body, "#+end_src" })
  local p = vim.treesitter.get_parser(buf, "org")
  p:parse(true)
  local seen = {}
  p:for_each_tree(function(_, lt)
    seen[lt:lang()] = true
  end)
  return seen
end

-- Dynamic injection: whatever parser is installed gets used.
check("lua block injects lua (control, was in old list)", injected("lua", "print(1)").lua == true)
check("vimdoc block injects vimdoc (NOT in old list)", injected("vimdoc", "*x*").vimdoc == true)
check(
  "markdown_inline block injects (NOT in old list)",
  injected("markdown_inline", "**b**").markdown_inline == true
)

-- Uppercase fence token still resolves (Neovim normalizes).
check("C (uppercase) injects c", injected("C", "int x;").c == true)

-- Unknown language: graceful no-op (only the org tree, no crash).
do
  local seen = injected("zzznotalang", "whatever")
  local only_org = true
  for l in pairs(seen) do
    if l ~= "org" then
      only_org = false
    end
  end
  check(
    "unknown language injects nothing (graceful)",
    only_org,
    "saw: " .. vim.inspect(vim.tbl_keys(seen))
  )
end

-- Alias registration: org-babel spellings map to the parser name.
local get_lang = vim.treesitter.language.get_lang
check("alias js -> javascript", get_lang("js") == "javascript", "got " .. tostring(get_lang("js")))
check("alias sh -> bash", get_lang("sh") == "bash", "got " .. tostring(get_lang("sh")))
check(
  "alias emacs-lisp -> elisp",
  get_lang("emacs-lisp") == "elisp",
  "got " .. tostring(get_lang("emacs-lisp"))
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("injection_dynamic_test: PASS")
os.exit(0)
