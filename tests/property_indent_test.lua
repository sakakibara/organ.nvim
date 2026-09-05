-- Property drawers written by the repeater (LAST_REPEAT) and by the archiver
-- (ARCHIVE_*) follow `todo.planning_indent`, so no writer leaves a drawer with
-- `:PROPERTIES:` at column 0 and indented keys inside it.
--
-- Emacs oracle (org 9.7.11, `emacs --batch -Q`, org-adapt-indentation nil):
--   `* Top / ** TODO Task / "   SCHEDULED: ..."` + (org-entry-put nil "FOO" "bar")
--   ->  "   :PROPERTIES:" / "   :FOO:      bar" / "   :END:"
--   i.e. Emacs matches the surrounding indentation; it does NOT write at
--   column 0.  (The comment this test replaces claimed the opposite.)
--
-- Run via: nvim --headless -l tests/property_indent_test.lua

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
  todo = { log_done = "time" },
})

local function drawer_of(lines)
  local out, inside = {}, false
  for _, l in ipairs(lines) do
    if l:match("^%s*:PROPERTIES:%s*$") then
      inside = true
    end
    if inside then
      out[#out + 1] = l
    end
    if inside and l:match("^%s*:END:%s*$") then
      break
    end
  end
  return out
end

local function assert_uniform(label, lines)
  local drawer = drawer_of(lines)
  assert(#drawer >= 3, label .. ": no property drawer in:\n" .. table.concat(lines, "\n"))
  local lead = drawer[1]:match("^([ \t]*)")
  for _, l in ipairs(drawer) do
    assert(
      l:match("^([ \t]*)") == lead,
      label .. ": ragged drawer indent:\n" .. table.concat(drawer, "\n")
    )
  end
  return lead
end

-- 1. LAST_REPEAT lands inside an already-indented drawer at that drawer's
--    indent, not at column 0.
do
  local path = org_dir .. "/rep.org"
  local fh = assert(io.open(path, "w"))
  fh:write(
    "* Top\n** TODO Task\n   SCHEDULED: <2026-01-01 Thu +1w>\n"
      .. "   :PROPERTIES:\n   :ID:        abc123def\n   :END:\n"
  )
  fh:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  local todo = require("organ.todo")
  todo._now_for_test = function()
    return "2026-01-05"
  end
  assert(todo.set(b, 2, "DONE") == nil)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local lead = assert_uniform("repeat", lines)
  assert(lead == "   ", "repeat: expected the existing 3-space indent, got " .. ("%q"):format(lead))
  assert(
    table.concat(lines, "\n"):find("   :LAST_REPEAT: ", 1, true),
    "repeat: LAST_REPEAT not written at the drawer indent:\n" .. table.concat(lines, "\n")
  )
end

-- 2. A fresh drawer created by the repeater uses the section indent.
do
  local path = org_dir .. "/rep2.org"
  local fh = assert(io.open(path, "w"))
  fh:write("* Top\n** TODO Task\n   SCHEDULED: <2026-01-01 Thu +1w>\n")
  fh:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  assert(require("organ.todo").set(b, 2, "DONE") == nil)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local lead = assert_uniform("fresh", lines)
  assert(lead == "   ", "fresh: expected `adapt` indent for level 2, got " .. ("%q"):format(lead))
end

-- 3. Archive injects its ARCHIVE_* drawer at the section indent too, so an
--    archive round trip cannot accumulate whitespace damage.
do
  local src = org_dir .. "/arc.org"
  local fh = assert(io.open(src, "w"))
  fh:write("* DONE Old\n   :PROPERTIES:\n   :ID:        xyz789abc\n   :END:\n   body\n")
  fh:close()
  local b = vim.fn.bufadd(src)
  vim.fn.bufload(b)
  vim.api.nvim_buf_call(b, function()
    vim.cmd("silent! write")
  end)
  assert(require("organ.archive").archive_subtree({ bufnr = b, line = 1 }) == nil)
  local arc = vim.fn.readfile(src .. "_archive")
  assert_uniform("archive", arc)
end

-- 4. `planning_indent = false` writes flush left, matching `emacs -Q`'s
--    `org-adapt-indentation = nil` output.
do
  require("organ").config.todo.planning_indent = false
  local path = org_dir .. "/flush.org"
  local fh = assert(io.open(path, "w"))
  fh:write("* Top\n** TODO Task\nSCHEDULED: <2026-01-01 Thu +1w>\n")
  fh:close()
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  assert(require("organ.todo").set(b, 2, "DONE") == nil)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local lead = assert_uniform("flush", lines)
  require("organ").config.todo.planning_indent = "adapt"
  assert(lead == "", "flush: expected column 0, got " .. ("%q"):format(lead))
end

vim.fn.delete(tmp, "rf")
io.write("property indent ok\n")
os.exit(0)
