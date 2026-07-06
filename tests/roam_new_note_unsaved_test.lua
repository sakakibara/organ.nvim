-- A brand-new note created from org -- a roam node (M-CR / :Org roam) or a
-- daily -- must open as an UNSAVED buffer and materialize on disk only when
-- written.  Creating one and quitting without typing leaves nothing behind
-- (not even the parent directory).  Both paths share
-- organ.roam.note.open_unsaved, so this test guards them together.
--
-- Run via: nvim --headless -l tests/roam_new_note_unsaved_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function fresh_roam_dir()
  -- tempname() is unique and does NOT exist yet, so we can assert the dir
  -- is not created until the first write.
  return vim.fn.tempname() .. "-roam"
end

local function has(bufnr, needle)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- Roam node create (M-CR / :Org roam create-on-no-match).
do
  local dir = fresh_roam_dir()
  require("organ").setup({ roam = { dir = dir } })
  require("organ.roam").create_node("Fresh Node")

  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  check("roam: opened a buffer under the roam dir", path:find(dir, 1, true) == 1, "path=" .. path)
  check("roam: buffer is unsaved (modified)", vim.bo[buf].modified == true)
  check("roam: seeded with :ID:", has(buf, ":ID:"))
  check("roam: seeded with #+title", has(buf, "#+title: Fresh Node"))
  check("roam: file NOT on disk before write", vim.fn.filereadable(path) == 0)
  check("roam: dir NOT created before write", vim.fn.isdirectory(dir) == 0)

  vim.cmd("write")
  check("roam: file exists after write", vim.fn.filereadable(path) == 1)
  check("roam: dir created on write", vim.fn.isdirectory(dir) == 1)
  check("roam: not modified after write", vim.bo[buf].modified == false)

  pcall(vim.fn.delete, dir, "rf")
end

-- Daily note.
do
  local dir = fresh_roam_dir()
  require("organ").setup({ roam = { dir = dir, dailies = { subdir = "daily" } } })
  require("organ.roam.dailies").for_date("2026-07-06")

  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  check("daily: buffer is unsaved (modified)", vim.bo[buf].modified == true)
  check("daily: file NOT on disk before write", vim.fn.filereadable(path) == 0)
  check("daily: daily dir NOT created before write", vim.fn.isdirectory(dir .. "/daily") == 0)

  vim.cmd("write")
  check("daily: file exists after write", vim.fn.filereadable(path) == 1)

  pcall(vim.fn.delete, dir, "rf")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("roam_new_note_unsaved_test: PASS")
os.exit(0)
