-- find.resolve_backend supports snacks / telescope / fzf_lua /
-- vim_ui_select, function spec, _test_stub, and "auto" autodetect.
-- We don't import the third-party pickers themselves — we only
-- verify the resolver's plumbing.
-- Run via: nvim --headless -l tests/find_backend_resolve_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local find = require("organ.find")

-- 1. Autodetect with no picker plugins loaded → falls back to the
-- built-in vim_ui_select backend (always available, no extra dep).
do
  package.loaded["snacks.picker"] = nil
  package.loaded["telescope"] = nil
  package.loaded["fzf-lua"] = nil
  _G.Snacks = nil
  assert(
    find._autodetect_backend() == "vim_ui_select",
    "autodetect should fall back to vim_ui_select with no plugin loaded; got "
      .. tostring(find._autodetect_backend())
  )
end

-- 2. Telescope-loaded → autodetect prefers it (when snacks absent).
do
  package.loaded["telescope"] = true -- stub
  assert(find._autodetect_backend() == "telescope", "telescope should win when only it is loaded")
  package.loaded["telescope"] = nil
end

-- 3. fzf-lua-loaded → detected.
do
  package.loaded["fzf-lua"] = true
  assert(
    find._autodetect_backend() == "fzf_lua",
    "fzf-lua detected; got " .. tostring(find._autodetect_backend())
  )
  package.loaded["fzf-lua"] = nil
end

-- 4. snacks wins over both.
do
  _G.Snacks = { picker = {} }
  package.loaded["telescope"] = true
  package.loaded["fzf-lua"] = true
  assert(
    find._autodetect_backend() == "snacks",
    "snacks wins by precedence; got " .. tostring(find._autodetect_backend())
  )
  _G.Snacks = nil
  package.loaded["telescope"] = nil
  package.loaded["fzf-lua"] = nil
end

-- 5. _test_stub backend captures invocation.
do
  local items = { { display = "x", title = "X" } }
  find.pick({
    backend = "_test_stub",
    source = "complete",
    items = items,
    default_action = "jump",
  })
  local last = require("organ.find.backend")._test_stub.last
  assert(last and last.items and last.items[1].display == "x", "test stub should record items")
end

io.write("find backend resolve ok\n")
os.exit(0)
