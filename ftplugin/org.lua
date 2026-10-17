-- ftplugin/org.lua
-- Runs once per org buffer (Neovim's standard ftplugin hook).
-- Installs buffer-local keymaps for structure, inline-edit, property, table,
-- todo, fold, indent, completion, and clock features.
--
-- setup() must have been called before any org buffer is opened, because
-- the config defaults (keymaps, enabled flags, etc.) live in organ.config.

local bufnr = vim.api.nvim_get_current_buf()

-- Activate tree-sitter highlighting (see grammar_install.start_highlighter
-- for why the bundled syntax is cleared).  A missing grammar starts a
-- background install that refreshes this buffer when it finishes and
-- reports its own failure, once.
local grammar = require("organ.grammar_install")
local missing = grammar.ensure()
local ok, err, inline_ok, inline_err = grammar.start_highlighter(bufnr)
if not missing then
  if not ok then
    grammar.warn_fallback(err)
  elseif not inline_ok then
    grammar.warn_inline(inline_err)
  end
end

-- Core: TODO keymaps, fold opts, indent, completion autocmd, clock keymaps.
require("organ.ftplugin.core").attach(bufnr)

-- Subtree manipulation keymaps.
require("organ.ftplugin.subtree").attach(bufnr)

-- Inline-edit keymaps.
require("organ.ftplugin.inline_edit").attach(bufnr)

-- Property keymaps.
require("organ.ftplugin.property").attach(bufnr)

-- Table cell navigation + menu keymaps.
require("organ.ftplugin.table").attach(bufnr)

-- Fast-tag-selection keymap.
require("organ.ftplugin.tag_select").attach(bufnr)

-- Org-tempo <Tab> install (no-op when the table ftplugin already wired Tab).
require("organ.ftplugin.tempo").attach(bufnr)

-- Trivial-binding registry (see lua/organ/keymaps.lua). The per-feature
-- ftplugin files above own the bindings whose callbacks carry real
-- logic (count repetition, mode dispatch, fallthrough); the registry
-- handles the rest.
require("organ.keymaps").attach(bufnr)
-- which-key.add() registration when which-key is loaded; no-op otherwise.
require("organ.keymaps").register_which_key()
