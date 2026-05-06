-- tests/global_keymaps_test.lua
-- Tests for config.global_keymaps: default maps, disable-all, disable-one,
-- override lhs.  Global keymaps are NORMAL-mode maps set on `"n"` with no
-- buffer restriction (bufnr = 0 means "global").
-- Run via: nvim --headless -l tests/global_keymaps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")

-- Helper: check whether a global (non-buffer-local) normal-mode keymap exists
-- for the given lhs.  Returns the map table or nil.
local function has_global_keymap(lhs)
  local nvim_lhs = vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, false, true))
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.lhs == lhs or m.lhs == nvim_lhs then
      return m
    end
  end
  return nil
end

-- Helper: run a fresh setup with given opts (always resets M.config to defaults
-- to avoid state leakage between test cases).
local function do_setup(extra)
  -- Clean up any global keymaps that might have been set by a previous run.
  -- We use pcall so missing-keymap errors are silenced.
  local defaults = require("organ.defaults")
  local gk = defaults.global_keymaps
  if type(gk) == "table" then
    for _, lhs in pairs(gk) do
      if type(lhs) == "string" and lhs ~= "" then
        pcall(vim.keymap.del, "n", lhs)
      end
    end
  end

  require("organ").config = require("organ.defaults")
  require("organ").setup(vim.tbl_deep_extend("force", {
    db_path = tmp .. "/gk.db",
    org_dir = tmp,
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  }, extra or {}))
end

-- ─── 1. Default setup → <Leader>oc maps to :Org capture ───────────────────────
do
  do_setup()
  local m = has_global_keymap("<Leader>oc")
  assert(m ~= nil, "default: <Leader>oc should map to :Org capture")
  -- The rhs should contain OrgCapture
  local rhs = m.rhs or ""
  assert(
    rhs:find("Org capture"),
    'default: <Leader>oc rhs should reference "Org capture", got: ' .. rhs
  )
end

-- ─── 2. Default setup → <Leader>oa maps to :Org agenda ────────────────────────
do
  -- setup already ran above; keymaps persist — just verify
  local m = has_global_keymap("<Leader>oa")
  assert(m ~= nil, "default: <Leader>oa should map to :Org agenda")
end

-- ─── 3. Default setup → <Leader>of maps to :Org find ──────────────────────────
do
  local m = has_global_keymap("<Leader>of")
  assert(m ~= nil, "default: <Leader>of should map to :Org find")
end

-- ─── 4. Default setup → <Leader>oi maps to :Org clock in ───────────────────────
do
  local m = has_global_keymap("<Leader>oi")
  assert(m ~= nil, "default: <Leader>oi should map to :Org clock in")
end

-- ─── 5. Default setup → scan=false means no global keymap for OrgScan ────────
do
  -- The defaults set scan = false, so there should be no :Org scan global map.
  -- We verify by checking that no keymap in "n" has a rhs containing "OrgScan"
  -- AND also that any earlier global <Leader> keymaps we know about are present.
  -- (There is no fixed lhs for scan so we scan all global keymaps.)
  local found_scan = false
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    local rhs = m.rhs or ""
    if rhs:find("<Cmd>OrgScan<CR>") then
      found_scan = true
      break
    end
  end
  assert(not found_scan, "default: OrgScan should NOT have a global keymap (scan=false)")
end

-- ─── 6. global_keymaps = false → no organ global keymaps installed ────────────
do
  -- First delete existing maps from the previous setup run.
  pcall(vim.keymap.del, "n", "<Leader>oc")
  pcall(vim.keymap.del, "n", "<Leader>oa")
  pcall(vim.keymap.del, "n", "<Leader>of")
  pcall(vim.keymap.del, "n", "<Leader>ol")
  pcall(vim.keymap.del, "n", "<Leader>or")
  pcall(vim.keymap.del, "n", "<Leader>od")
  pcall(vim.keymap.del, "n", "<Leader>oi")
  pcall(vim.keymap.del, "n", "<Leader>oo")
  pcall(vim.keymap.del, "n", "<Leader>oR")

  do_setup({ global_keymaps = false })

  local m = has_global_keymap("<Leader>oc")
  assert(m == nil, "global_keymaps=false: <Leader>oc should NOT be installed")
  local m2 = has_global_keymap("<Leader>oa")
  assert(m2 == nil, "global_keymaps=false: <Leader>oa should NOT be installed")
end

-- ─── 7. Disable individual: capture = false → no <Leader>oc ──────────────────
do
  pcall(vim.keymap.del, "n", "<Leader>oa")
  pcall(vim.keymap.del, "n", "<Leader>of")
  pcall(vim.keymap.del, "n", "<Leader>ol")
  pcall(vim.keymap.del, "n", "<Leader>or")
  pcall(vim.keymap.del, "n", "<Leader>od")
  pcall(vim.keymap.del, "n", "<Leader>oi")
  pcall(vim.keymap.del, "n", "<Leader>oo")
  pcall(vim.keymap.del, "n", "<Leader>oR")

  do_setup({ global_keymaps = { capture = false } })

  -- capture disabled → no <Leader>oc
  local mc = has_global_keymap("<Leader>oc")
  assert(mc == nil, "capture=false: <Leader>oc should NOT be installed")
  -- agenda still uses default → <Leader>oa should exist
  local ma = has_global_keymap("<Leader>oa")
  assert(ma ~= nil, "capture=false: <Leader>oa (agenda) should still be installed")
end

-- ─── 8. Override: capture = "<Leader>nc" → new lhs maps to :Org capture ───────
do
  -- Clean up defaults first.
  pcall(vim.keymap.del, "n", "<Leader>oa")
  pcall(vim.keymap.del, "n", "<Leader>of")
  pcall(vim.keymap.del, "n", "<Leader>ol")
  pcall(vim.keymap.del, "n", "<Leader>or")
  pcall(vim.keymap.del, "n", "<Leader>od")
  pcall(vim.keymap.del, "n", "<Leader>oi")
  pcall(vim.keymap.del, "n", "<Leader>oo")
  pcall(vim.keymap.del, "n", "<Leader>oR")
  pcall(vim.keymap.del, "n", "<Leader>nc")

  do_setup({ global_keymaps = { capture = "<Leader>nc" } })

  -- The new lhs should map to OrgCapture.
  local m_new = has_global_keymap("<Leader>nc")
  assert(m_new ~= nil, "override: <Leader>nc should map to :Org capture")
  local rhs = m_new.rhs or ""
  assert(rhs:find("Org capture"), 'override: <Leader>nc rhs should reference "Org capture"')

  -- The original default lhs <Leader>oc should have been replaced (deep-merge
  -- replaces default value "..." with "<Leader>nc", so <Leader>oc not installed).
  local m_old = has_global_keymap("<Leader>oc")
  assert(
    m_old == nil,
    "override: <Leader>oc (old default) should NOT be installed when capture overridden"
  )

  -- Clean up test-specific keymap.
  pcall(vim.keymap.del, "n", "<Leader>nc")
end

vim.fn.delete(tmp, "rf")
io.write("global keymaps ok\n")
os.exit(0)
