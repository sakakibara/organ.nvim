-- A `#+begin_src LANG` block injects the tree-sitter parser named by LANG.
-- The injection query uses the raw language token; org-babel spellings that
-- differ from the parser name (sh/shell/zsh -> bash, emacs-lisp -> elisp,
-- ...) resolve through the aliases organ registers in `organ.ts_lang`. This
-- verifies a native token (bash) and an aliased token (sh) both inject bash.
--
-- Run via: nvim --headless -l tests/injection_src_block_lang_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })
-- Register the org-babel language aliases (sh -> bash, ...) the same way
-- organ.setup() does, so aliased tokens resolve to their parser.
require("organ.ts_lang").register()

local function try_lang(name)
  local files = vim.api.nvim_get_runtime_file("parser/" .. name .. ".so", true)
  if #files == 0 then
    return false
  end
  return pcall(vim.treesitter.language.add, name, { path = files[1] })
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function injected_langs(lang_token, body)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "#+begin_src " .. lang_token,
    body,
    "#+end_src",
    "",
  })
  vim.bo[buf].filetype = "org"
  vim.treesitter.start(buf, "org")
  local p = vim.treesitter.get_parser(buf, "org")
  p:parse(true)
  local set = {}
  for child_lang in pairs(p:children()) do
    set[child_lang] = true
  end
  return set
end

-- Sanity: lua (no `\b` in pattern) has always worked.
if try_lang("lua") then
  local langs = injected_langs("lua", "print('hi')")
  check("lua block injects lua", langs.lua == true, "got " .. vim.inspect(langs))
end

-- Regression target: bash (was using `\b`).
if try_lang("bash") then
  local langs = injected_langs("bash", "echo hi")
  check("bash block injects bash", langs.bash == true, "got " .. vim.inspect(langs))
  -- `sh` and `zsh` share the bash pattern; verify both alternates fire.
  local langs_sh = injected_langs("sh", "echo hi")
  check("sh block injects bash", langs_sh.bash == true, "got " .. vim.inspect(langs_sh))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("injection_src_block_lang_test: PASS")
os.exit(0)
