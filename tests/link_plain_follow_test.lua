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

-- org-link-plain-re: the path must end with a non-punctuation char, a
-- `/`, or a balanced paren group.
do
  local cases = {
    { "see https://example.com/foo_ now", "https://example.com/foo_", "https://example.com/foo" },
    { "see https://example.com/a- now", "https://example.com/a-", "https://example.com/a" },
    { "see http://x.com/# now", "http://x.com/#", "http://x.com/" },
    { "see https://example.com/foo~ now", "https://example.com/foo~", "https://example.com/foo" },
    { "see https://x.com/path/ now", "https://x.com/path/", "https://x.com/path/" },
    { "see https://x.com/a_(b) now", "https://x.com/a_(b)", "https://x.com/a_(b)" },
    { "see https://x.com/a=1&b=2 now", "https://x.com/a=1&b=2", "https://x.com/a=1&b=2" },
  }
  for _, c in ipairs(cases) do
    local got = target_at(c[1], 6)
    check("trailing punctuation: " .. c[2], got == c[3], tostring(got))
  end
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

-- org-link-bracket-re allows `]` inside the description; the cursor on
-- the description still resolves the bracket target.
do
  local opened
  local saved = vim.ui.open
  vim.ui.open = function(url)
    opened = url
  end
  buf_with({
    "see [[https://bracket.example][Intro [v2] notes]] here",
  })
  vim.api.nvim_win_set_cursor(0, { 1, 40 })
  link.follow()
  vim.ui.open = saved
  check("bracket description containing ]", opened == "https://bracket.example", tostring(opened))
end

-- plain_link_at must stay linear in line length.  A quadratic scan froze
-- nvim un-interruptibly on a pasted data URI (`<CR>` and `gx` both route
-- here), so bound the wall clock, not just the result.  The bound is
-- ~200x the linear cost and ~1/7 of the quadratic cost at this size.
do
  local function seconds(line)
    local t0 = vim.loop.hrtime()
    link.plain_link_at(line, 1)
    return (vim.loop.hrtime() - t0) / 1e9
  end
  local cases = {
    { "no colon anywhere", string.rep("x", 32768) },
    { "colon at every other char", string.rep("x:", 16384) },
    { "long base64 data URI", "data:image/png;base64," .. string.rep("A", 32768) },
    { "long trailing paren run", "http://example.com/a" .. string.rep(")", 32768) },
    { "long trailing punctuation run", "http://example.com/a" .. string.rep(".", 32768) },
  }
  for _, c in ipairs(cases) do
    local dt = seconds(c[2])
    check(
      "plain_link_at stays linear: " .. c[1],
      dt < 1.0,
      string.format("took %.3fs on a %d-char line", dt, #c[2])
    )
  end
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("link_plain_follow_test: PASS")
