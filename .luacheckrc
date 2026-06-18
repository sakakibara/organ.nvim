std = "luajit"
read_globals = { "vim" }
-- Writable vim submodules (setting these is normal Neovim usage, not a
-- read-only-field violation).
globals = {
  "vim.g",
  "vim.b",
  "vim.w",
  "vim.t",
  "vim.v",
  "vim.o",
  "vim.go",
  "vim.bo",
  "vim.wo",
  "vim.opt",
  "vim.opt_local",
  "vim.env",
}
max_line_length = false
-- Unused function arguments are common in fixed callback signatures
-- (autocmd ev, range params) and rarely indicate a bug.
unused_args = false
-- Ignore stylistic-only diagnostics so the gate fails on bug-class findings
-- (unused/dead locals) rather than idiomatic Lua name reuse.
--   4.. shadowing,  542 empty if branch,  581 negation-can-be-simplified
ignore = { "4.[123]", "542", "581" }
exclude_files = {
  "tests/deps/",
  "org-mode/",
  "org-roam/",
  "tree-sitter-org/",
  "tree-sitter-organ/",
  "tree-sitter-organ-inline/",
}
