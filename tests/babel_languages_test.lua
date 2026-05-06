-- Babel language registry: every documented language has a runner; runners
-- exist for shells, scripting, tempfile-interpreters, and compiled.
-- We don't actually invoke the runners here (they require N external
-- toolchains); we only verify the registry shape so a typo doesn't slip in.
-- Run via: nvim --headless -l tests/babel_languages_test.lua

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

local expected = {
  "sh",
  "bash",
  "zsh",
  "fish",
  "python",
  "lua",
  "ruby",
  "perl",
  "javascript",
  "js",
  "php",
  "R",
  "r",
  "typescript",
  "ts",
  "scheme",
  "racket",
  "ocaml",
  "haskell",
  "elixir",
  "clojure",
  "c",
  "cpp",
  "rust",
  "go",
  "java",
  "sql",
  "sqlite",
  "rest",
}

for _, lang in ipairs(expected) do
  assert(type(babel.languages[lang]) == "function", "missing runner for language: " .. lang)
end

-- Header parser still works; quick sanity.
local lang, args = babel.parse_header("#+BEGIN_SRC rust :tangle out.rs")
assert(
  lang == "rust" and args.tangle == "out.rs",
  "parse_header rust: " .. tostring(lang) .. "/" .. tostring(args.tangle)
)

-- Optional smoke: actually run sh if available (most test environments
-- have sh; skip otherwise).
if vim.fn.executable("sh") == 1 then
  local out, err, rc = babel.languages.sh("echo hello", { vars = {} })
  assert(rc == 0, "sh exit code: " .. tostring(rc))
  assert(out == "hello", "sh stdout: " .. tostring(out))
end

io.write("babel languages ok\n")
os.exit(0)
