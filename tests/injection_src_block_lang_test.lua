-- Regression: #match? predicates auto-prepend `\v` (very-magic) in
-- nvim treesitter; in that mode end-of-word is bare `>`, not `\b`
-- or `\>`.  Patterns using `\b` (bash, javascript, typescript, go,
-- c, cpp, java, html, kotlin, R, dot, dockerfile, makefile) were
-- silently failing — only languages with no boundary (lua, python,
-- rust, ruby, etc.) injected.  Verify by checking that bash gets
-- a language tree on a `#+begin_src bash` block.
--
-- Run via: nvim --headless -l tests/injection_src_block_lang_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

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
