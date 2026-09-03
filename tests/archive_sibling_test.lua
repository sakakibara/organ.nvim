-- archive.archive_to_sibling moves a subtree under a `* Archive` headline
-- in the same buffer, creating Archive when absent.
-- Run via: nvim --headless -l tests/archive_sibling_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

require("organ").setup({
  db_path = tmp .. "/x.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { log_done = false },
  archive = { add_metadata = true, sibling_heading = "Archive" },
})

local archive = require("organ.archive")

-- 1. Archive when no `* Archive` exists → creates it at end and moves subtree under it.
do
  local fixture = org_dir .. "/a.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[* TODO Item to archive
  body line
* Other
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)

  local err = archive.archive_to_sibling({ bufnr = b, line = 1 })
  assert(err == nil, "archive failed: " .. tostring(err))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local joined = table.concat(lines, "\n")
  assert(joined:find("* Archive", 1, true), "Archive heading must exist:\n" .. joined)
  assert(
    joined:find("** TODO Item to archive", 1, true),
    "moved subtree should be a level-2 child of Archive:\n" .. joined
  )
  assert(joined:find(":ARCHIVE_TIME:", 1, true), "ARCHIVE_TIME prop present")
  assert(joined:find(":ARCHIVE_TODO:%s*TODO"), "ARCHIVE_TODO prop captures original state")
  -- Source subtree gone from the original location.
  assert(not joined:find("^%* TODO Item to archive"), "source subtree removed")
  assert(joined:find("* Other", 1, true), "* Other preserved")
end

-- 2. Archive when `* Archive` already exists → appends under it without duplicating.
do
  local fixture = org_dir .. "/b.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write([[* TODO Newest
* Archive
** Older
]])
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  local err = archive.archive_to_sibling({ bufnr = b, line = 1 })
  assert(err == nil, "archive failed: " .. tostring(err))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local joined = table.concat(lines, "\n")
  -- One Archive headline only.
  local n_archive = 0
  for _, l in ipairs(lines) do
    if l == "* Archive" then
      n_archive = n_archive + 1
    end
  end
  assert(n_archive == 1, "expected one '* Archive'; got " .. n_archive)
  assert(joined:find("** TODO Newest", 1, true), "Newest moved as level-2 child")
  assert(joined:find("** Older", 1, true), "Older still under Archive")
end

-- An entry that closes the `* Archive` section stays under Archive
-- (the insertion point is computed after the subtree is removed).
do
  local fixture = org_dir .. "/d.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write("* Archive\n** Old\nold body\n* Other\nother body\n")
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  local err = archive.archive_to_sibling({ bufnr = b, line = 2 })
  assert(err == nil, "archive failed: " .. tostring(err))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local joined = table.concat(lines, "\n")
  assert(lines[1] == "* Archive" and lines[2] == "** Old", joined)
  assert(lines[#lines - 1] == "* Other" and lines[#lines] == "other body", joined)
end

-- The TODO keyword stays on the moved headline.
do
  local fixture = org_dir .. "/e.org"
  local fh = assert(io.open(fixture, "w"))
  fh:write("* TODO Keep state\n* Archive\n")
  fh:close()
  local b = vim.fn.bufadd(fixture)
  vim.fn.bufload(b)
  local err = archive.archive_to_sibling({ bufnr = b, line = 1 })
  assert(err == nil, "archive failed: " .. tostring(err))
  local joined = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  assert(joined:find("\n** TODO Keep state\n", 1, true), joined)
end

vim.fn.delete(tmp, "rf")
io.write("archive sibling ok\n")
os.exit(0)
