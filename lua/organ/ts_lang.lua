-- Register org-babel language spellings as tree-sitter aliases so that
-- `#+begin_src LANG` highlighting (queries/org/injections.scm injects the
-- raw LANG token) resolves the Emacs/babel name of a language to the
-- Neovim parser, not just the parser's own name.  Only names that DIFFER
-- from the parser name need an alias; identical names resolve natively.
--
-- Registering an alias for a parser the user hasn't installed is harmless:
-- the injection is simply a no-op until the parser exists.

local M = {}

-- parser name -> { org-babel / Emacs spellings that map to it }
local ALIASES = {
  bash = { "sh", "shell", "zsh" },
  javascript = { "js", "node" },
  typescript = { "ts" },
  cpp = { "c++", "cxx" },
  yaml = { "yml" },
  markdown = { "md" },
  haskell = { "hs" },
  kotlin = { "kt" },
  ruby = { "rb" },
  python = { "py" },
  elisp = { "emacs-lisp", "el" },
  commonlisp = { "lisp", "cl" },
  vim = { "vimscript" },
  make = { "makefile" },
  ocaml = { "ml" },
  rust = { "rs" },
}

local registered = false

-- Idempotent: safe to call on every setup().
function M.register()
  if registered then
    return
  end
  registered = true
  for lang, aliases in pairs(ALIASES) do
    pcall(vim.treesitter.language.register, lang, aliases)
  end
end

return M
