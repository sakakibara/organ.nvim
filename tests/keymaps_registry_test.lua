-- keymaps registry: lazy.nvim-style spec defaults + user override merging.
-- Run via: nvim --headless -l tests/keymaps_registry_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local function fresh_setup(opts)
  require("organ").config = require("organ.defaults")
  require("organ").setup(vim.tbl_deep_extend("force", {
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    debounce_ms = 0,
    watcher = { enabled = false },
  }, opts or {}))
end

local function fresh_buf()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  return b
end

local function has_keymap(b, lhs, mode)
  mode = mode or "n"
  local nvim_lhs = vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, false, true))
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, mode)) do
    if m.lhs == lhs or vim.fn.keytrans(m.lhsraw or m.lhs) == nvim_lhs then
      return m
    end
  end
  return nil
end

-- 1. Defaults install verbatim.
do
  fresh_setup()
  local b = fresh_buf()
  require("organ.keymaps").attach(b)
  assert(has_keymap(b, "<LocalLeader>aa"), "archive subtree default missing")
  assert(has_keymap(b, "<LocalLeader>fs"), "footnote sort default missing")
  assert(has_keymap(b, "<M-t>"), "M-t TODO chord missing")
  assert(has_keymap(b, "gO"), "outline (gO) default missing")
end

-- 2. User adds a new binding via the lazy.nvim-style `keys` list.
do
  fresh_setup({
    keys = {
      { "<LocalLeader>z", "OrgArchiveToSibling", desc = "custom archive" },
    },
  })
  local b = fresh_buf()
  require("organ.keymaps").attach(b)
  assert(has_keymap(b, "<LocalLeader>z"), "user-added lhs should install")
  -- Default also still installed.
  assert(has_keymap(b, "<LocalLeader>as"), "default sibling still present")
end

-- 3. User disables a default with `{ lhs, false }`.
do
  fresh_setup({
    keys = {
      { "<LocalLeader>aa", false },
    },
  })
  local b = fresh_buf()
  require("organ.keymaps").attach(b)
  assert(not has_keymap(b, "<LocalLeader>aa"), "default should be removed by `{ lhs, false }`")
  -- A different default still works.
  assert(has_keymap(b, "<LocalLeader>as"), "unrelated default unaffected")
end

-- 4. User overrides the rhs/desc of an existing default lhs.
do
  fresh_setup({
    keys = {
      { "<LocalLeader>aa", "OrgArchiveToSibling", desc = "swapped" },
    },
  })
  local b = fresh_buf()
  require("organ.keymaps").attach(b)
  local m = has_keymap(b, "<LocalLeader>aa")
  assert(m, "override should still install at the same lhs")
  assert(
    m.desc and m.desc:find("swapped", 1, true),
    "desc should reflect override; got " .. tostring(m.desc)
  )
end

-- 5. Function rhs works.
do
  local fired = false
  fresh_setup({
    keys = {
      {
        "<LocalLeader>x",
        function()
          fired = true
        end,
        desc = "fn rhs",
      },
    },
  })
  local b = fresh_buf()
  require("organ.keymaps").attach(b)
  local m = has_keymap(b, "<LocalLeader>x")
  assert(m, "fn-rhs binding should install")
  m.callback()
  assert(fired, "fn-rhs callback should fire")
end

-- 6. Multi-mode binding.
do
  fresh_setup({
    keys = {
      { "<M-CR>", function() end, desc = "multi", mode = { "n", "i" } },
    },
  })
  local b = fresh_buf()
  require("organ.keymaps").attach(b)
  assert(has_keymap(b, "<M-CR>", "n"), "n-mode mapping installed")
  assert(has_keymap(b, "<M-CR>", "i"), "i-mode mapping installed")
end

-- 7. iter_bindings yields the resolved set.
do
  fresh_setup()
  local n = #require("organ.keymaps").iter_bindings()
  assert(n > 30, "expected 30+ default bindings; got " .. n)
end

io.write("keymaps registry ok\n")
os.exit(0)
