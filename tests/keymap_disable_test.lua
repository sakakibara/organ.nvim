-- tests/keymap_disable_test.lua
-- Tests for Rule 2: keymap disable patterns across installers.
--   - cfg.<feature>.keymaps = false  → no keymaps for that feature
--   - cfg.<feature>.keymaps.<name> = false → that one binding skipped; siblings installed
-- Run via: nvim --headless -l tests/keymap_disable_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

local function has_keymap(bufnr, lhs, mode)
  mode = mode or "n"
  local nvim_lhs = vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, false, true))
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
    if m.lhs == lhs or vim.fn.keytrans(m.lhsraw or m.lhs) == nvim_lhs then
      return m
    end
  end
  return nil
end

local function open_org_buf(setup_opts)
  -- Reset to defaults before each setup to avoid test-state accumulation.
  require("organ").config = require("organ.defaults")
  require("organ").setup(vim.tbl_deep_extend("force", {
    db_path = tmp .. "/kd.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  }, setup_opts or {}))
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "org"
  return b
end

-- ─── structure: keymaps = false → no structure keymaps ───────────────────────
do
  local b = open_org_buf({ structure = { keymaps = false } })
  local demote_norm = (">>"):gsub("<", "<lt>")
  local promote_norm = ("<<"):gsub("<", "<lt>")
  assert(
    not (has_keymap(b, ">>") or has_keymap(b, demote_norm)),
    "structure >> should be disabled with keymaps=false"
  )
  assert(
    not (has_keymap(b, "<<") or has_keymap(b, promote_norm)),
    "structure << should be disabled with keymaps=false"
  )
  assert(not has_keymap(b, "gK"), "structure gK should be disabled with keymaps=false")
  assert(not has_keymap(b, "gJ"), "structure gJ should be disabled with keymaps=false")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── structure: keymaps.<name> = false → that one skipped; sibling installed ─
-- Each operation has a primary slot (e.g. promote_subtree = "<M-h>") AND
-- an alt slot for the Vim-native fallback (promote_subtree_alt = "<<").
-- Disabling `promote_subtree` removes ONLY the primary; the alt stays.
-- To remove `<<` too, set `promote_subtree_alt = false`.
do
  local b = open_org_buf({
    structure = {
      keymaps = {
        promote_subtree = false,
        promote_subtree_alt = false,
      },
    },
  })
  -- both promote_subtree bindings disabled.
  local promote_norm = ("<<"):gsub("<", "<lt>")
  assert(
    not (has_keymap(b, "<<") or has_keymap(b, promote_norm)),
    "promote_subtree << should be disabled when alt also false"
  )
  assert(not has_keymap(b, "<M-h>"), "promote_subtree <M-h> should be disabled")
  -- demote_subtree still installed.
  local demote_norm = (">>"):gsub("<", "<lt>")
  assert(
    has_keymap(b, ">>") or has_keymap(b, demote_norm),
    "demote_subtree >> should still be installed"
  )
  assert(has_keymap(b, "<M-l>"), "demote_subtree <M-l> should still be installed")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── inline_edit: keymaps = false → no inline_edit keymaps ───────────────────
do
  local b = open_org_buf({ inline_edit = { keymaps = false } })
  assert(not has_keymap(b, "<C-a>"), "<C-a> should be disabled with inline_edit.keymaps=false")
  assert(not has_keymap(b, "<C-x>"), "<C-x> should be disabled with inline_edit.keymaps=false")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── inline_edit: keymaps.decrement = false → increment still installed ───────
do
  local b = open_org_buf({
    inline_edit = { keymaps = { decrement = false } },
  })
  assert(not has_keymap(b, "<C-x>"), "<C-x> (decrement) should be disabled")
  assert(has_keymap(b, "<C-a>"), "<C-a> (increment) should still be installed")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── property: keymaps = false → no property keymaps ─────────────────────────
do
  local b = open_org_buf({ property = { keymaps = false } })
  assert(not has_keymap(b, "<LocalLeader>ps"), "property set should be disabled")
  assert(not has_keymap(b, "<LocalLeader>pd"), "property delete should be disabled")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── table: keymaps = false → no table insert-mode keymaps ───────────────────
-- Tempo also installs <Tab> in insert mode unless disabled, so opt out of
-- both to verify table's bindings are gone.
do
  local b = open_org_buf({ table = { keymaps = false }, tempo = { enabled = false } })
  assert(
    not has_keymap(b, "<Tab>", "i"),
    "table <Tab> in insert mode should be disabled with keymaps=false"
  )
  assert(
    not has_keymap(b, "<S-Tab>", "i"),
    "table <S-Tab> in insert mode should be disabled with keymaps=false"
  )
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── table: keymaps.next_cell = false → prev_cell still installed ─────────────
do
  local b = open_org_buf({
    table = { keymaps = { next_cell = false } },
  })
  assert(not has_keymap(b, "<Tab>", "i"), "table next_cell <Tab> insert should be disabled")
  assert(has_keymap(b, "<S-Tab>", "i"), "table prev_cell <S-Tab> insert should still work")
  vim.api.nvim_buf_delete(b, { force = true })
end

vim.fn.delete(tmp, "rf")
io.write("keymap disable ok\n")
os.exit(0)
