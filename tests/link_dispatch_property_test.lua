-- Unit tests for link.dispatch_property_value — token-membership match,
-- 0/1/≥2 cases, multi-value ROAM_REFS, empty value, picker-on-many.
-- Run via: nvim --headless -l tests/link_dispatch_property_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/notes"
vim.fn.mkdir(org_dir, "p")

local fixture = vim.fn.resolve(org_dir .. "/refs.org")
local fh = assert(io.open(fixture, "w"))
fh:write([=[* Single Ref
  :PROPERTIES:
  :ROAM_REFS: https://single.example.com
  :END:
  body.

* Multi Ref
  :PROPERTIES:
  :ROAM_REFS: https://a.example.com @cite-key https://b.example.com
  :END:
  body.

* Other Single
  :PROPERTIES:
  :ROAM_REFS: https://other.example.com
  :END:
  body.

* Bibkey-bearing
  :PROPERTIES:
  :BIBKEY: knuth1984
  :END:
  body.

* Shared Ref Alpha
  :PROPERTIES:
  :ROAM_REFS: shared-token
  :END:
  body.

* Shared Ref Beta
  :PROPERTIES:
  :ROAM_REFS: shared-token
  :END:
  body.
]=])
fh:close()

require("organ").setup({
  db_path = tmp .. "/d.db",
  org_dir = org_dir,
  notify = true,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  find = { backend = "_test_stub" },
})
require("organ").scan_blocking(org_dir, 5000)

local link = require("organ.link")
assert(
  type(link.dispatch_property_value) == "function",
  "dispatch_property_value should be exported from organ.link"
)

-- 1. Single match → jump (file open + cursor on Single Ref headline line).
do
  vim.cmd("enew") -- get away from any prior file
  link.dispatch_property_value({
    kind = "property_value",
    key = "ROAM_REFS",
    value = "https://single.example.com",
  })
  local cur_path = vim.fn.resolve(vim.api.nvim_buf_get_name(0))
  assert(cur_path == fixture, "expected fixture open; got " .. cur_path)
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
  assert(
    text == "* Single Ref",
    "expected cursor on '* Single Ref'; got line " .. cur_line .. " = " .. tostring(text)
  )
end

-- 2. Multi-value: matching one token of N hits the right headline.
do
  vim.cmd("enew")
  link.dispatch_property_value({
    kind = "property_value",
    key = "ROAM_REFS",
    value = "@cite-key",
  })
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
  assert(
    text == "* Multi Ref",
    "expected cursor on '* Multi Ref'; got line " .. cur_line .. " = " .. tostring(text)
  )
end

-- 3. Different KEY (BIBKEY) → finds the Bibkey-bearing headline.
do
  vim.cmd("enew")
  link.dispatch_property_value({
    kind = "property_value",
    key = "BIBKEY",
    value = "knuth1984",
  })
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local text = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
  assert(text == "* Bibkey-bearing", "expected cursor on '* Bibkey-bearing'; got line " .. cur_line)
end

-- 4. ≥2 matches → snacks picker (test stub) receives pre-filtered items.
do
  local stub = require("organ.find.backend")._test_stub
  stub.last = nil -- reset
  link.dispatch_property_value({
    kind = "property_value",
    key = "ROAM_REFS",
    value = "shared-token",
  })
  assert(stub.last and stub.last.items, "picker should have been invoked")
  assert(#stub.last.items == 2, "picker should receive 2 items; got " .. #stub.last.items)
  -- The 2 items should be Shared Ref Alpha and Beta.
  local titles = { stub.last.items[1].title, stub.last.items[2].title }
  table.sort(titles)
  assert(
    titles[1] == "Shared Ref Alpha" and titles[2] == "Shared Ref Beta",
    "expected Alpha + Beta; got " .. vim.inspect(titles)
  )
end

-- 5. Zero matches → notify-WARN, file unchanged.
do
  local prev_path = vim.api.nvim_buf_get_name(0)
  local notified
  local original_notify = vim.notify
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end

  link.dispatch_property_value({
    kind = "property_value",
    key = "ROAM_REFS",
    value = "https://no-such-ref.example.com",
  })

  vim.notify = original_notify
  assert(
    notified and notified.msg:find("no headline with"),
    "expected 'no headline with' notify; got " .. tostring(notified and notified.msg)
  )
  assert(notified.lvl == vim.log.levels.WARN, "expected WARN level")
  assert(vim.api.nvim_buf_get_name(0) == prev_path, "buffer should not change on no match")
end

-- 6. Empty value → notify-WARN (no token equals "").
do
  local notified
  local original_notify = vim.notify
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end

  link.dispatch_property_value({
    kind = "property_value",
    key = "ROAM_REFS",
    value = "",
  })

  vim.notify = original_notify
  assert(
    notified and notified.msg:find("no headline with"),
    "expected notify on empty value; got " .. tostring(notified and notified.msg)
  )
end

-- 7. KEY not present in any property → notify-WARN.
do
  local notified
  local original_notify = vim.notify
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end

  link.dispatch_property_value({
    kind = "property_value",
    key = "NOSUCHKEY",
    value = "anything",
  })

  vim.notify = original_notify
  assert(
    notified and notified.msg:find("no headline with"),
    "expected notify on missing key; got " .. tostring(notified and notified.msg)
  )
end

-- 8. Case-sensitive KEY: lowercase doesn't match uppercase property.
do
  local notified
  local original_notify = vim.notify
  vim.notify = function(msg, lvl)
    notified = { msg = msg, lvl = lvl }
  end

  link.dispatch_property_value({
    kind = "property_value",
    key = "roam_refs",
    value = "https://single.example.com",
  })

  vim.notify = original_notify
  assert(
    notified and notified.msg:find("no headline with"),
    "lowercase key should not match uppercase ROAM_REFS"
  )
end

vim.fn.delete(tmp, "rf")
io.write("link dispatch property ok\n")
os.exit(0)
