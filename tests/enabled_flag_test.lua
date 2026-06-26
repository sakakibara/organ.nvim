-- tests/enabled_flag_test.lua
-- Tests for unified `enabled` flag across features (Rule 3).
-- Run via: nvim --headless -l tests/enabled_flag_test.lua

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

-- Helper: open a fresh org buffer with the given setup config.
local function open_org_buf(setup_opts)
  -- Reset to defaults before each setup to avoid test-state accumulation.
  require("organ").config = require("organ.defaults")
  require("organ").setup(vim.tbl_deep_extend("force", {
    db_path = tmp .. "/ef.db",
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

-- ─── Command deletion: defaults first ────────────────────────────────────────
-- NOTE: Commands deleted by setup() are gone for the rest of the Neovim
-- session (plugin/organ.lua runs exactly once).  All "commands present when
-- enabled=true" checks MUST run before any test that calls setup() with
-- enabled=false for the same feature.

do
  require("organ").config = require("organ.defaults")
  require("organ").setup({
    db_path = tmp .. "/ef_default.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  })
  local cmd = require("organ").cmd
  assert(
    cmd("promote") ~= nil,
    "subcommand `promote` should exist when structure.enabled=true (default)"
  )
  assert(cmd("scan") ~= nil, "subcommand `scan` (core) must always be present")
  assert(cmd("status") ~= nil, "subcommand `status` (core) must always be present")
end

-- ─── structure.enabled = false → no structure keymaps ────────────────────────
do
  local b = open_org_buf({ structure = { enabled = false } })
  -- "<<" normalises to "<lt><lt>" in nvim keymap lookup
  local promote_lhs = ("<<"):gsub("<", "<lt>")
  local demote_lhs = (">>"):gsub("<", "<lt>")
  local found = has_keymap(b, "<<")
    or has_keymap(b, promote_lhs)
    or has_keymap(b, ">>")
    or has_keymap(b, demote_lhs)
  assert(not found, "structure keymaps should be disabled when structure.enabled=false")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── structure.enabled = true (default) → structure keymaps installed ─────────
do
  local b = open_org_buf({ structure = { enabled = true } })
  local promote_lhs = ("<<"):gsub("<", "<lt>")
  local found = has_keymap(b, "<<") or has_keymap(b, promote_lhs)
  assert(found, "structure keymaps should be installed when structure.enabled=true")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── inline_edit.enabled = false → no inline_edit keymaps ────────────────────
do
  local b = open_org_buf({ inline_edit = { enabled = false } })
  local found = has_keymap(b, "<C-a>") or has_keymap(b, "<C-x>")
  assert(not found, "inline_edit keymaps should be disabled when inline_edit.enabled=false")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── property.enabled = false → no property keymaps ──────────────────────────
do
  local b = open_org_buf({ property = { enabled = false } })
  local found = has_keymap(b, "<LocalLeader>ps") or has_keymap(b, "<LocalLeader>pd")
  assert(not found, "property keymaps should be disabled when property.enabled=false")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── table.enabled = false → no table keymaps (Tab in insert mode) ───────────
-- The insert-mode <Tab> keymap may still be present when tempo.enabled is
-- true (it shares the same dispatcher); disable both to verify table off
-- truly removes the binding.
do
  local b = open_org_buf({ table = { enabled = false }, tempo = { enabled = false } })
  local found = has_keymap(b, "<Tab>", "i")
  assert(not found, "table <Tab> in insert mode should be disabled when table.enabled=false")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── clock.enabled = false → clock keymaps not installed ─────────────────────
do
  local b = open_org_buf({
    clock = { enabled = false, keymaps = { in_ = "<Leader>ci" } },
  })
  local found = has_keymap(b, "<Leader>ci")
  assert(not found, "clock keymaps should not install when clock.enabled=false")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── clock.enabled = true + keymap set → keymap IS installed ─────────────────
do
  local b = open_org_buf({
    clock = { enabled = true, keymaps = { in_ = "<Leader>ci" } },
  })
  local found = has_keymap(b, "<Leader>ci")
  assert(found, "clock keymaps should install when clock.enabled=true and keymap set")
  vim.api.nvim_buf_delete(b, { force = true })
end

-- ─── Command deletion: disabled feature commands removed from namespace ───────

-- Helper that calls setup() with a single feature disabled and
-- returns the path resolver.
local function cmd_after_disable(feat, extra_opts)
  require("organ").config = require("organ.defaults")
  require("organ").setup(vim.tbl_deep_extend("force", {
    db_path = tmp .. "/ef_cmds.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  }, extra_opts or {}, { [feat] = { enabled = false } }))
  return require("organ").cmd
end

-- structure disabled → `promote` gone; `scan` (core) still present
do
  local cmd = cmd_after_disable("structure")
  assert(cmd("promote") == nil, "`promote` should be removed when structure.enabled=false")
  assert(cmd("demote") == nil, "`demote` should be removed when structure.enabled=false")
  assert(cmd("scan") ~= nil, "`scan` (core) must survive structure.enabled=false")
end

-- capture disabled → `capture` gone
do
  local cmd = cmd_after_disable("capture")
  assert(cmd("capture") == nil, "`capture` should be removed when capture.enabled=false")
  assert(
    cmd("capture_prompt") == nil,
    "`capture_prompt` should be removed when capture.enabled=false"
  )
end

-- clock disabled → `clock in` gone
do
  local cmd = cmd_after_disable("clock")
  assert(cmd("clock in") == nil, "`clock in` should be removed when clock.enabled=false")
  assert(cmd("clock out") == nil, "`clock out` should be removed when clock.enabled=false")
end

-- table disabled → `table insert_row` gone
do
  local cmd = cmd_after_disable("table")
  assert(
    cmd("table insert_row") == nil,
    "`table insert_row` should be removed when table.enabled=false"
  )
end

-- find disabled → `find` gone
do
  local cmd = cmd_after_disable("find")
  -- The `find` group itself may still exist (other find children get
  -- removed individually); what we assert is that the bare leaf and
  -- the listed children are gone.
  assert(
    not (cmd("find") and cmd("find").fn),
    "`find` bare leaf should be removed when find.enabled=false"
  )
  assert(cmd("find tag") == nil, "`find tag` should be removed when find.enabled=false")
end

-- roam disabled → `roam` gone
do
  local cmd = cmd_after_disable("roam")
  assert(
    not (cmd("roam") and cmd("roam").fn),
    "`roam` bare leaf should be removed when roam.enabled=false"
  )
  assert(cmd("roam insert") == nil, "`roam insert` should be removed when roam.enabled=false")
end

-- sparse disabled → `sparse_tree todo` gone
do
  local cmd = cmd_after_disable("sparse")
  assert(
    cmd("sparse_tree todo") == nil,
    "`sparse_tree todo` should be removed when sparse.enabled=false"
  )
end

-- property disabled → `set_property` gone
do
  local cmd = cmd_after_disable("property")
  assert(cmd("set_property") == nil, "`set_property` should be removed when property.enabled=false")
  assert(
    cmd("delete_property") == nil,
    "`delete_property` should be removed when property.enabled=false"
  )
end

-- inline_edit disabled → `increment` gone
do
  local cmd = cmd_after_disable("inline_edit")
  assert(cmd("increment") == nil, "`increment` should be removed when inline_edit.enabled=false")
  assert(cmd("decrement") == nil, "`decrement` should be removed when inline_edit.enabled=false")
end

vim.fn.delete(tmp, "rf")
io.write("enabled flag ok\n")
os.exit(0)
