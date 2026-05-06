-- Behavioral test: archiving a subtree to its archive file.
--
-- Opens a real org file with a TODO subtree, places the cursor on
-- the headline, fires `:Org archive subtree`, and asserts:
--   - the subtree is removed from the source file
--   - it has been written to <source>_archive
--
-- Exercises:
--   :Org archive subtree -> organ.archive.commands.archive_subtree
--   organ.archive.archive_subtree (find headline, compute subtree end,
--     append to archive_path, delete from source)
--
-- Run via: nvim --headless -l tests/behavioral/archive_subtree_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/notes.org"
vim.fn.writefile({
  "#+TITLE: Notes",
  "",
  "* DONE Old project",
  "  Body line 1.",
  "  Body line 2.",
  "** Sub task",
  "* TODO Active",
}, fixture)
local archive_path = fixture .. "_archive"

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

vim.cmd("filetype plugin on")
vim.cmd("edit " .. fixture)
local org_buf = vim.api.nvim_get_current_buf()
vim.wait(500, function()
  return vim.bo[org_buf].filetype == "org"
end)

-- Cursor on "DONE Old project" (line 3).
vim.api.nvim_win_set_cursor(0, { 3, 0 })

-- Pre-state.
do
  local lines = vim.api.nvim_buf_get_lines(org_buf, 0, -1, false)
  local has_done = false
  for _, l in ipairs(lines) do
    if l:match("^%* DONE Old project") then
      has_done = true
    end
  end
  check("pre-state: source has the DONE subtree", has_done)
  check("pre-state: archive file does not yet exist", vim.fn.filereadable(archive_path) == 0)
end

vim.cmd("Org archive subtree")

-- Source buffer should no longer contain the DONE headline or its
-- subtree (children too).
do
  local lines = vim.api.nvim_buf_get_lines(org_buf, 0, -1, false)
  local has_done, has_sub = false, false
  for _, l in ipairs(lines) do
    if l:match("^%* DONE Old project") then
      has_done = true
    end
    if l:match("^%*%* Sub task") then
      has_sub = true
    end
  end
  check("post: DONE headline removed from source", not has_done, table.concat(lines, "|"))
  check("post: child Sub task removed from source", not has_sub)
  -- TODO Active should still be there.
  local has_active = false
  for _, l in ipairs(lines) do
    if l:match("^%* TODO Active") then
      has_active = true
    end
  end
  check("post: TODO Active still present", has_active)
end

-- Archive file should contain the moved subtree.
do
  check("post: archive file exists", vim.fn.filereadable(archive_path) == 1)
  if vim.fn.filereadable(archive_path) == 1 then
    local arc = vim.fn.readfile(archive_path)
    -- The archive subsystem demotes the headline under an "* Archive"
    -- container and moves the TODO state into an :ARCHIVE_TODO: property
    -- (Emacs parity).  Title text is preserved on the headline itself.
    local has_title, has_archive_todo, has_sub = false, false, false
    for _, l in ipairs(arc) do
      if l:match("Old project") then
        has_title = true
      end
      if l:match(":ARCHIVE_TODO:%s*DONE") then
        has_archive_todo = true
      end
      if l:match("Sub task") then
        has_sub = true
      end
    end
    check("post: archive contains the headline title", has_title, table.concat(arc, "|"))
    check("post: archive records ARCHIVE_TODO=DONE", has_archive_todo)
    check("post: archive contains child Sub task", has_sub)
  end
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("archive_subtree_test: PASS")
