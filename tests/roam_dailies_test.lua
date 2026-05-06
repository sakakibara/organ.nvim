-- tests/roam_dailies_test.lua
-- Run via: nvim --headless -l tests/roam_dailies_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, "p")

require("organ").setup({
  org_dir = tmpdir,
  db_path = tmpdir .. "/organ.db",
  roam = { dir = tmpdir .. "/roam" },
})

local dailies = require("organ.roam.dailies")

local function exists(p)
  return vim.loop.fs_stat(p) ~= nil
end
local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

----------------------------------------------------------------------
-- today() creates the daily file.
do
  dailies.today()
  local iso = os.date("%Y-%m-%d")
  local path = tmpdir .. "/roam/daily/" .. iso .. ".org"
  assert(exists(path), "today daily exists at " .. path)
  -- Default template includes #+title:
  local lines = vim.fn.readfile(path)
  local has_title = false
  for _, l in ipairs(lines) do
    if l:find("^#%+title: ") then
      has_title = true
    end
  end
  assert(has_title, "default template has #+title:")
end

----------------------------------------------------------------------
-- today() called twice opens same file (no overwrite).
do
  local iso = os.date("%Y-%m-%d")
  local path = tmpdir .. "/roam/daily/" .. iso .. ".org"
  -- Modify existing daily file.
  local f = assert(io.open(path, "w"))
  f:write("MARKER\n")
  f:close()
  dailies.today()
  -- Read back; should still contain MARKER.
  local lines = vim.fn.readfile(path)
  assert(lines[1] == "MARKER", "no overwrite on second open")
end

----------------------------------------------------------------------
-- for_date creates a specific-date file.
do
  dailies.for_date("2026-12-25")
  assert(exists(tmpdir .. "/roam/daily/2026-12-25.org"))
end

----------------------------------------------------------------------
-- Custom template honored.
do
  require("organ").setup({
    org_dir = tmpdir,
    db_path = tmpdir .. "/organ.db",
    roam = {
      dir = tmpdir .. "/roam",
      dailies = {
        template = function(iso)
          return { "CUSTOM " .. iso }
        end,
      },
    },
  })
  -- Need a fresh date to avoid hitting an existing file.
  dailies.for_date("2030-01-01")
  local lines = vim.fn.readfile(tmpdir .. "/roam/daily/2030-01-01.org")
  assert_eq(lines[1], "CUSTOM 2030-01-01")
end

io.write("roam dailies ok\n")
