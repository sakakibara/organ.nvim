-- Behavioral test: open or create today's roam daily note.
--
-- Configures roam.dir under a tmp directory, runs `:Org
-- roam_daily_today`, and verifies that <roam>/daily/<today>.org gets
-- created with the default template and is the current buffer.
--
-- Exercises:
--   :Org roam daily today -> organ.roam.commands.roam_daily_today
--   organ.roam.dailies.today -> _open_or_create
--   default_template emission (#+title, :ID:, :PROPERTIES:)
--   atomic write + :edit of the daily file
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

local tmp = vim.fn.tempname()
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

-- Pre-state: file does not yet exist.
check("pre-state: today's daily does not exist", vim.fn.filereadable(expected_path) == 0)

vim.cmd("filetype plugin on")
vim.cmd("Org roam daily today")

-- Post: file exists, current buffer is editing it.
check("post: today's daily file created", vim.fn.filereadable(expected_path) == 1)

local cur_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
check(
  "post: current buffer is the daily file",
  cur_path == vim.fn.fnamemodify(expected_path, ":p"),
  cur_path
)

-- Default template content: PROPERTIES + ID + #+title with today's ISO.
local lines = vim.fn.readfile(expected_path)
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
check("post: file has :PROPERTIES: drawer", has_props, table.concat(lines, "|"))
check("post: file has an :ID: line", has_id)
check("post: file has #+title with today's date", has_title)

-- Re-running should not recreate (no error, same content).
local before_content = vim.fn.readfile(expected_path)
vim.cmd("Org roam daily today")
local after_content = vim.fn.readfile(expected_path)
check(
  "second run is idempotent (file unchanged)",
  table.concat(before_content, "\n") == table.concat(after_content, "\n")
)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("roam_daily_test: PASS")
