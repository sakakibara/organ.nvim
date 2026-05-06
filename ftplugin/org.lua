-- ftplugin/org.lua
-- Runs once per org buffer (Neovim's standard ftplugin hook).
-- Installs buffer-local keymaps for structure, inline-edit, property, table,
-- todo, fold, indent, completion, and clock features.
--
-- setup() must have been called before any org buffer is opened, because
-- the config defaults (keymaps, enabled flags, etc.) live in organ.config.

local bufnr = vim.api.nvim_get_current_buf()

-- Activate tree-sitter highlighting and force-unload Neovim's bundled
-- `syntax/org.vim` for this buffer. The legacy syntax has a buggy
-- `orgCodeInline` region (matching `~...~`) that bleeds to EOF whenever
-- a property value like `:DIR: ~/path` appears, so we want it gone.
--
-- vim.treesitter.start() sets `b:current_syntax = ""` which *prevents*
-- future syntax loading, but doesn't unload syntax that already loaded.
-- The explicit `syntax clear` below covers that case.
local ok, err = pcall(vim.treesitter.start, bufnr, "org")
if ok then
  pcall(function()
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("syntax clear") end)
  end)
else
  vim.notify(
    "organ: tree-sitter parser not available — highlighting falls back to "
    .. "Neovim's bundled syntax/org.vim, which has a known bleed bug.\n"
    .. "Run :lua require('organ.grammar_install').install() to fix.\n"
    .. "(detail: " .. tostring(err) .. ")",
    vim.log.levels.WARN)
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
