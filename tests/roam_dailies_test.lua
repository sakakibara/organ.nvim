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

-- today() opens an unsaved daily buffer; the file appears only on save.
do
  dailies.today()
  local iso = os.date("%Y-%m-%d")
  local path = tmpdir .. "/roam/daily/" .. iso .. ".org"
  assert(not exists(path), "new daily is not written until save")
  -- Default template (in the buffer) includes #+title:
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local has_title = false
  for _, l in ipairs(lines) do
    if l:find("^#%+title: ") then
      has_title = true
    end
  end
  assert(has_title, "default template has #+title:")
  vim.cmd("write")
  assert(exists(path), "today daily written on save at " .. path)
end

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

-- for_date opens a specific-date daily; file appears on save.
do
  dailies.for_date("2026-12-25")
  local path = tmpdir .. "/roam/daily/2026-12-25.org"
  assert(not exists(path), "specific-date daily unsaved until write")
  vim.cmd("write")
  assert(exists(path))
end

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
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert_eq(lines[1], "CUSTOM 2030-01-01")
end

io.write("roam dailies ok\n")
