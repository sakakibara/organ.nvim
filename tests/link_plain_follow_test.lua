-- link.follow recognizes org plain links (a bare `https://...` etc.
-- outside `[[...]]` brackets) and angle links (`<scheme:...>`), so gx
-- on a bare URL opens it.  Plain detection is limited to schemes the
-- resolver knows, so prose like "note: this" never becomes a link.
--
-- Run via: nvim --headless -l tests/link_plain_follow_test.lua

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

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local link = require("organ.link")

-- plain_link_at: span detection on a raw line.
local function target_at(line, col)
  local lk = link.plain_link_at(line, col)
  return lk and lk.target or nil
end

do
  local line = "see https://example.com for info"
  check(
    "bare https URL under cursor",
    target_at(line, 5) == "https://example.com",
    tostring(target_at(line, 5))
  )
  check(
    "cursor at last URL char",
    target_at(line, 23) == "https://example.com",
    tostring(target_at(line, 23))
  )
  check("cursor outside the URL", target_at(line, 25) == nil, tostring(target_at(line, 25)))
end

do
  local line = "read https://example.com/foo."
  check(
    "trailing sentence punctuation trimmed",
    target_at(line, 10) == "https://example.com/foo",
    tostring(target_at(line, 10))
  )
end

do
  local line = "wiki https://en.wikipedia.org/wiki/Foo_(bar) yes"
  check(
    "balanced trailing paren kept",
    target_at(line, 10) == "https://en.wikipedia.org/wiki/Foo_(bar)",
    tostring(target_at(line, 10))
  )
end

do
  local line = "(see https://example.com)"
  check(
    "unbalanced closing paren trimmed",
    target_at(line, 10) == "https://example.com",
    tostring(target_at(line, 10))
  )
end

do
  local line = "note: this is prose, deadline: tomorrow"
  check("unknown scheme is not a link", target_at(line, 2) == nil, tostring(target_at(line, 2)))
  check("unknown scheme mid-line", target_at(line, 24) == nil, tostring(target_at(line, 24)))
end

do
  local line = "mail mailto:someone@example.org now"
  check(
    "mailto plain link",
    target_at(line, 8) == "mailto:someone@example.org",
    tostring(target_at(line, 8))
  )
end

do
  local line = "xhttps://example.com is not a link start"
  check(
    "scheme must start at a word boundary",
    target_at(line, 3) == nil,
    tostring(target_at(line, 3))
  )
end

do
  local line = "angle <https://example.com/a b> link"
  check(
    "angle link may contain spaces",
    target_at(line, 12) == "https://example.com/a b",
    tostring(target_at(line, 12))
  )
  check(
    "cursor on the closing angle bracket",
    target_at(line, 31) == "https://example.com/a b",
    tostring(target_at(line, 31))
  )
end

-- follow(): a bare URL in a buffer dispatches kind=url via vim.ui.open.
local function buf_with(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

do
  local opened
  local saved = vim.ui.open
  vim.ui.open = function(url)
    opened = url
  end
  buf_with({
    "* H",
    "visit https://example.com/page today",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 10 })
  link.follow()
  vim.ui.open = saved
  check("follow opens bare URL", opened == "https://example.com/page", tostring(opened))
end

-- Bracket links keep priority: cursor inside [[...][...]] resolves the
-- bracket target even when the description would match a plain link.
do
  local opened
  local saved = vim.ui.open
  vim.ui.open = function(url)
    opened = url
  end
  buf_with({
    "[[https://bracket.example][https://desc.example]]",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 30 })
  link.follow()
  vim.ui.open = saved
  check("bracket link wins over plain match", opened == "https://bracket.example", tostring(opened))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("link_plain_follow_test: PASS")
