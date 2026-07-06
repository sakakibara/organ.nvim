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

-- spelling -> parser name (reverse of ALIASES), built once.
local reverse
local function reverse_aliases()
  if reverse then
    return reverse
  end
  reverse = {}
  for lang, aliases in pairs(ALIASES) do
    for _, a in ipairs(aliases) do
      reverse[a] = lang
    end
  end
  return reverse
end

-- Resolve a `#+begin_src` LANG token to its tree-sitter parser name.
function M.resolve(token)
  token = token:lower()
  return reverse_aliases()[token] or vim.treesitter.language.get_lang(token) or token
end

-- List the distinct tree-sitter parser names used by `#+begin_src` blocks
-- in `bufnr`, with org-babel spellings (sh, emacs-lisp, ...) resolved.
--
-- A src-block language is not a buffer filetype, so a filetype-keyed
-- on-demand parser installer never sees it.  Feed this list to such an
-- installer (e.g. `require("nvim-treesitter").install(...)`) on org buffer
-- open to make embedded languages highlight.  organ installs nothing
-- itself -- this only reports what the buffer wants.
function M.src_block_parsers(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  M.register()
  local seen, out = {}, {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local token = line:lower():match("^%s*#%+begin_src%s+(%S+)")
    if token then
      local lang = M.resolve(token)
      if lang and not seen[lang] then
        seen[lang] = true
        out[#out + 1] = lang
      end
    end
  end
  table.sort(out)
  return out
end

return M
