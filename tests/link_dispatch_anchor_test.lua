-- Unit tests for link.dispatch_edit_file — anchor classification, DB lookup,
-- scan fallback, cursor positioning, and not-found notify.
-- Run via: nvim --headless -l tests/link_dispatch_anchor_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/notes"
vim.fn.mkdir(org_dir, "p")

-- Indexed fixture: known headlines, custom_id, and content for text/line scans.
-- vim.fn.resolve normalises symlinks (e.g. /var → /private/var on macOS) so
-- that comparisons with nvim_buf_get_name() are stable across platforms.
local indexed = vim.fn.resolve(org_dir .. "/indexed.org")
local fh = assert(io.open(indexed, "w"))
fh:write([=[* Alpha Heading
  :PROPERTIES:
  :CUSTOM_ID: alpha-cust
  :END:
  Body alpha.

* Beta Heading
  :PROPERTIES:
  :CUSTOM_ID: beta-cust
  :END:
  Body beta with the marker UNIQUE_TEXT_TOKEN here.

* Gamma Heading
  Plain body.
]=])
fh:close()

require("organ").setup({
  db_path = tmp .. "/d.db",
  org_dir = org_dir,
  notify = true,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local link = require("organ.link")
assert(
  type(link.dispatch_edit_file) == "function",
  "dispatch_edit_file should be exported from organ.link"
)

local function load_indexed_buffer()
  vim.cmd("edit " .. vim.fn.fnameescape(indexed))
end

-- 1. Headline anchor via DB → cursor at headline line.
do
  link.dispatch_edit_file({
    kind = "edit_file",
    path = indexed,
    anchor = "*Beta Heading",
  })
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  assert(
    text == "* Beta Heading",
    "expected cursor on '* Beta Heading'; got line " .. line .. " = " .. tostring(text)
  )
end

-- 2. Custom-id anchor via DB → cursor at the headline that owns the property.
do
  link.dispatch_edit_file({
    kind = "edit_file",
    path = indexed,
    anchor = "#alpha-cust",
  })
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  assert(
    text == "* Alpha Heading",
    "expected cursor on '* Alpha Heading'; got line " .. line .. " = " .. tostring(text)
  )
end

-- 3. Line anchor → cursor at exactly that line.
do
  link.dispatch_edit_file({
    kind = "edit_file",
    path = indexed,
    anchor = "5",
  })
  local line = vim.api.nvim_win_get_cursor(0)[1]
  assert(line == 5, "expected line 5; got " .. line)
end

-- 4. Free-text anchor → linear scan, lands on first matching line.
do
  link.dispatch_edit_file({
    kind = "edit_file",
    path = indexed,
    anchor = "UNIQUE_TEXT_TOKEN",
  })
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  assert(
    text:find("UNIQUE_TEXT_TOKEN", 1, true),
    "expected line containing UNIQUE_TEXT_TOKEN; got line " .. line .. " = " .. tostring(text)
  )
end

-- 5. Anchor not found → file open, notify-WARN issued, no crash.
do
  load_indexed_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  local notified
  local original_notify = vim.notify
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end

  link.dispatch_edit_file({
    kind = "edit_file",
    path = indexed,
    anchor = "*NoSuchHeading",
  })

  vim.notify = original_notify
  assert(
    notified and notified.msg:find("anchor not found"),
    "expected notify with 'anchor not found'; got " .. tostring(notified and notified.msg)
  )
  assert(notified.lvl == vim.log.levels.WARN, "expected WARN level")
  assert(
    vim.api.nvim_buf_get_name(0) == indexed,
    "expected file still open; got " .. vim.api.nvim_buf_get_name(0)
  )
end

-- 6. Unindexed file with *Heading anchor → DB miss → scan fallback hits.
do
  local orphan_dir = tmp .. "/orphan"
  vim.fn.mkdir(orphan_dir, "p")
  local orphan = orphan_dir .. "/loose.org"
  local f = assert(io.open(orphan, "w"))
  f:write("* Loose Heading\n  body\n")
  f:close()
  -- Deliberately NOT indexed (orphan_dir is not org_dir; no scan fired).

  link.dispatch_edit_file({
    kind = "edit_file",
    path = orphan,
    anchor = "*Loose Heading",
  })
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  assert(
    text == "* Loose Heading",
    "expected cursor on '* Loose Heading' via scan fallback; got line " .. line
  )
end

-- 7. Anchor with no anchor field → file open, no cursor change crash.
do
  link.dispatch_edit_file({ kind = "edit_file", path = indexed, anchor = nil })
  assert(
    vim.api.nvim_buf_get_name(0) == indexed,
    "expected file open; got " .. vim.api.nvim_buf_get_name(0)
  )
end

-- 8. Line anchor exceeding buffer length → no crash (pcall swallow).
do
  local ok = pcall(link.dispatch_edit_file, {
    kind = "edit_file",
    path = indexed,
    anchor = "9999",
  })
  assert(ok, "should not raise on out-of-range line anchor")
end

-- 9. Scan fallback ignores TODO keyword, priority, statistics cookie,
-- COMMENT and tags, and compares words case-insensitively
-- (Emacs `org-link-search` matches against `(org-get-heading t t t t)`).
do
  local orphan_dir = tmp .. "/orphan2"
  vim.fn.mkdir(orphan_dir, "p")
  local orphan = vim.fn.resolve(orphan_dir .. "/decorated.org")
  local f = assert(io.open(orphan, "w"))
  f:write(table.concat({
    "#+TODO: INBOX | ARCHIVED",
    "* Intro",
    "* INBOX [#A] Deep dive [1/2] :work:",
    "  body",
    "* COMMENT Draft   notes",
    "",
  }, "\n"))
  f:close()

  local function line_after(anchor)
    link.dispatch_edit_file({ kind = "edit_file", path = orphan, anchor = anchor })
    local line = vim.api.nvim_win_get_cursor(0)[1]
    return vim.api.nvim_buf_get_lines(0, line - 1, line, false)[1]
  end

  local got = line_after("*Deep dive")
  assert(
    got == "* INBOX [#A] Deep dive [1/2] :work:",
    "expected decorated headline via scan fallback; got " .. tostring(got)
  )
  got = line_after("*deep DIVE")
  assert(
    got == "* INBOX [#A] Deep dive [1/2] :work:",
    "expected case-insensitive headline match; got " .. tostring(got)
  )
  got = line_after("*Draft notes")
  assert(got == "* COMMENT Draft   notes", "expected COMMENT headline; got " .. tostring(got))
end

vim.fn.delete(tmp, "rf")
io.write("link dispatch anchor ok\n")
os.exit(0)
