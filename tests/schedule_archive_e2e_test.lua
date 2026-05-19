-- E2E: schedule a headline → file updated → re-indexed → headline appears
-- in agenda within the date window. Then archive that subtree → file
-- modified, archive file created → re-indexed → no longer in primary
-- query, present in archive file.
--
-- Run via: nvim --headless -l tests/schedule_archive_e2e_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local data_dir = tmp .. "/data"
vim.fn.mkdir(data_dir, "p")
local original_stdpath = vim.fn.stdpath
vim.fn.stdpath = function(w)
  if w == "data" then
    return data_dir
  end
  return original_stdpath(w)
end

local parser_path = original_stdpath("data") .. "/organ/parser/org.so"
if vim.fn.filereadable(parser_path) ~= 1 then
  io.write("(skipped: parser not installed)\nschedule_archive_e2e_test: SKIP\n")
  vim.fn.stdpath = original_stdpath
  vim.fn.delete(tmp, "rf")
  os.exit(0)
end

local fixture = org_dir .. "/work.org"
do
  local f = assert(io.open(fixture, "w"))
  f:write("* TODO Standup\n  prep\n* Other thing\n  body\n")
  f:close()
end

require("organ").setup({
  db_path = tmp .. "/sa.db",
  org_dir = org_dir,
  parser_path = parser_path,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  mtime_skip = false,
  hash_skip = false,
})
require("organ").scan_blocking(org_dir, 5000)

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- 1. Schedule the Standup headline for today via _set_planning.
-- ---------------------------------------------------------------------------
local schedule = require("organ.schedule")
local sb = vim.fn.bufadd(fixture)
vim.fn.bufload(sb)
vim.bo[sb].filetype = "org"

local today_iso = os.date("%Y-%m-%d")
schedule._set_planning(sb, 1, "SCHEDULED", today_iso)
vim.api.nvim_buf_call(sb, function()
  vim.cmd("write")
end)

-- File should now have a SCHEDULED: line.
local lines = vim.fn.readfile(fixture)
local has_scheduled
for _, l in ipairs(lines) do
  if l:find("SCHEDULED: <" .. today_iso, 1, true) then
    has_scheduled = true
    break
  end
end
check(
  "schedule: SCHEDULED line written to file",
  has_scheduled,
  "file:\n" .. table.concat(lines, "\n")
)

-- ---------------------------------------------------------------------------
-- 2. Re-index → query.agenda for today's window includes Standup.
-- ---------------------------------------------------------------------------
require("organ").scan_blocking(org_dir, 5000)

local query = require("organ.query")
local rows = query.agenda({ from = today_iso, to = today_iso, types = { "scheduled" } })
local in_agenda
for _, r in ipairs(rows) do
  if r.title == "Standup" then
    in_agenda = true
    break
  end
end
check(
  "agenda: scheduled heading appears in today's window",
  in_agenda,
  "agenda rows: " .. vim.inspect(vim.tbl_map(function(r)
    return r.title
  end, rows))
)

-- ---------------------------------------------------------------------------
-- 3. Archive the Standup subtree.
-- ---------------------------------------------------------------------------
local archive = require("organ.archive")
local err = archive.archive_subtree({ bufnr = sb, line = 1 })
check("archive: returns no error", err == nil, "err: " .. tostring(err))

vim.api.nvim_buf_call(sb, function()
  vim.cmd("write")
end)

-- Standup gone from src.
local lines_after = vim.fn.readfile(fixture)
local src_still_has_standup = false
for _, l in ipairs(lines_after) do
  if l:match("^%*+%s+TODO Standup") or l:match("^%*+%s+Standup") then
    src_still_has_standup = true
  end
end
check(
  "archive: source file no longer contains Standup",
  not src_still_has_standup,
  "src after:\n" .. table.concat(lines_after, "\n")
)

-- Archive file was created. The default `archive.location` is
-- `"%s_archive::"` (matches Emacs's `org-archive-location`), where
-- `%s` is the source basename -- so work.org → work.org_archive.
local archive_file = fixture .. "_archive"
check(
  "archive: archive file created",
  vim.fn.filereadable(archive_file) == 1,
  "expected " .. archive_file
)
local archive_lines = vim.fn.filereadable(archive_file) == 1 and vim.fn.readfile(archive_file) or {}
local archive_has_standup = false
for _, l in ipairs(archive_lines) do
  if l:find("Standup", 1, true) then
    archive_has_standup = true
    break
  end
end
check(
  "archive: archive file contains Standup",
  archive_has_standup,
  "archive contents:\n" .. table.concat(archive_lines, "\n")
)

-- ---------------------------------------------------------------------------
-- 4. Re-index. Standup should now be in archive_file, NOT src.
-- ---------------------------------------------------------------------------
require("organ").scan_blocking(org_dir, 5000)
local where_is_standup
for _, r in ipairs(query.headlines()) do
  if r.title == "Standup" then
    where_is_standup = r.file_path
  end
end
check(
  "post-archive: Standup is indexed under the archive file",
  where_is_standup == archive_file,
  "got " .. tostring(where_is_standup)
)

vim.fn.stdpath = original_stdpath
vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("schedule_archive_e2e_test: PASS")
