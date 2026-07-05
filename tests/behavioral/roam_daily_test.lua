-- Behavioral test: open today's roam daily note.
--
-- A brand-new daily opens as an UNSAVED buffer seeded with the template --
-- it becomes a file on disk only when the user saves.  Peeking at today's
-- daily and quitting without typing leaves nothing behind (matches Emacs
-- org-roam capture).
--
-- Exercises:
--   :Org roam daily today -> organ.roam.commands.roam_daily_today
--   organ.roam.dailies.today -> _open_or_create
--   default_template emission (#+title, :ID:, :PROPERTIES:)
--   deferred write: file appears only on :write
--
-- Run via: nvim --headless -l tests/behavioral/roam_daily_test.lua

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

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local roam_dir = tmp .. "/roam"

require("organ").setup({
  db_path = tmp .. "/behavioral.db",
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  roam = { dir = roam_dir },
})

local today = os.date("%Y-%m-%d")
local expected_path = roam_dir .. "/daily/" .. today .. ".org"

check("pre-state: today's daily does not exist", vim.fn.filereadable(expected_path) == 0)

vim.cmd("filetype plugin on")
vim.cmd("Org roam daily today")

-- Post-open: NO file yet -- the daily lives in an unsaved buffer.
check("post-open: no file written yet", vim.fn.filereadable(expected_path) == 0)

local cur_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
check(
  "post-open: current buffer is named the daily path",
  cur_path == vim.fn.fnamemodify(expected_path, ":p"),
  cur_path
)
check("post-open: buffer is modified (unsaved template)", vim.bo.modified == true)

-- The template content is in the BUFFER.
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local has_props, has_id, has_title = false, false, false
for _, l in ipairs(lines) do
  if l:match("^:PROPERTIES:") then
    has_props = true
  end
  if l:match("^:ID:%s+%S+") then
    has_id = true
  end
  if l == "#+title: " .. today then
    has_title = true
  end
end
check("post-open: buffer has :PROPERTIES: drawer", has_props, table.concat(lines, "|"))
check("post-open: buffer has an :ID: line", has_id)
check("post-open: buffer has #+title with today's date", has_title)

-- Saving turns the buffer into a file with the same content.
vim.cmd("write")
check("post-write: daily file created on save", vim.fn.filereadable(expected_path) == 1)
check(
  "post-write: file matches the buffer",
  table.concat(vim.fn.readfile(expected_path), "\n") == table.concat(lines, "\n")
)

-- Re-opening the now-existing daily edits it in place (no recreate/overwrite).
vim.cmd("enew")
vim.cmd("Org roam daily today")
check(
  "second run edits the existing file",
  vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p") == vim.fn.fnamemodify(expected_path, ":p")
)
check(
  "second run is idempotent (file unchanged)",
  table.concat(vim.fn.readfile(expected_path), "\n") == table.concat(lines, "\n")
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("roam_daily_test: PASS")
