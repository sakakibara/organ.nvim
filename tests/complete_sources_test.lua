-- New completion sources: TODO keywords, tags, directives.
-- Run via: nvim --headless -l tests/complete_sources_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

package.loaded["organ.query"] = {
  agenda = function()
    return {}
  end,
  headlines = function()
    return {
      { tags = { "work", "urgent" } },
      { tags = { "work" } },
      { tags = { "home" } },
    }
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAITING", "|", "DONE", "CANCELLED" } },
  tags = { alist = { "buildtag" } },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local todo = require("organ.complete.todo")
local tags = require("organ.complete.tags")
local dir = require("organ.complete.directive")

local function with_buffer(lines, fn)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  fn(b)
  vim.api.nvim_buf_delete(b, { force = true })
end

-- TODO source
with_buffer({ "* T", "  body" }, function(b)
  -- col=3 → just past `* T`.
  local p = todo.cursor_partial(b, 1, 3)
  check("todo: partial 'T' detected", p == "T")
  local items = todo.completion_items(p)
  local labels = vim.tbl_map(function(i)
    return i.label
  end, items)
  check("todo: TODO present", vim.tbl_contains(labels, "TODO"))
  check("todo: NEXT excluded (doesn't start with T)", not vim.tbl_contains(labels, "NEXT"))
end)

with_buffer({ "* ", "  body" }, function(b)
  local p = todo.cursor_partial(b, 1, 2)
  check("todo: empty partial after `* ` returns ''", p == "")
  local items = todo.completion_items(p)
  -- All non-`|` keywords surface.
  check("todo: all 5 keywords surface for empty partial", #items == 5)
end)

with_buffer({ "Body line", "* TODO Foo" }, function(b)
  -- Cursor on body line — not a headline.
  local p = todo.cursor_partial(b, 1, 5)
  check("todo: nil on non-headline line", p == nil)
end)

-- Tag source
with_buffer({ "* TODO Foo  :w" }, function(b)
  local p = tags.cursor_partial(b, 1, 14) -- right after the `w`
  check("tags: partial 'w' detected", p == "w")
  local items = tags.completion_items(p)
  local labels = vim.tbl_map(function(i)
    return i.label
  end, items)
  check("tags: 'work' surfaces", vim.tbl_contains(labels, "work"))
  check("tags: 'home' filtered out", not vim.tbl_contains(labels, "home"))
end)

with_buffer({ "* TODO Foo  :" }, function(b)
  local p = tags.cursor_partial(b, 1, 13) -- right after the `:`
  check("tags: empty partial after `:` returns ''", p == "")
  local items = tags.completion_items(p)
  -- All known tags + alist entry.
  local labels = vim.tbl_map(function(i)
    return i.label
  end, items)
  check("tags: most-frequent first (work uses=2 vs urgent uses=1)", labels[1] == "work")
  check("tags: alist 'buildtag' present (uses=0 ok)", vim.tbl_contains(labels, "buildtag"))
end)

with_buffer({ "* TODO Foo" }, function(b)
  -- No `:` typed yet.
  local p = tags.cursor_partial(b, 1, 10)
  check("tags: nil when no tag region opened", p == nil)
end)

-- Directive source
with_buffer({ "#+TIT" }, function(b)
  local p = dir.cursor_partial(b, 1, 5)
  check("directive: partial 'TIT' detected", p == "TIT")
  local items = dir.completion_items(p)
  local labels = vim.tbl_map(function(i)
    return i.label
  end, items)
  check("directive: '#+TITLE' present", vim.tbl_contains(labels, "#+TITLE"))
  check(
    "directive: 'TITLE' insertText carries trailing ': '",
    items[1].insertText:find("TITLE: ", 1, true) ~= nil
  )
end)

with_buffer({ "#+begin_s" }, function(b)
  local p = dir.cursor_partial(b, 1, 9)
  check("directive: 'begin_s' partial", p == "begin_s")
  local items = dir.completion_items(p)
  local has_src = false
  for _, it in ipairs(items) do
    if it.label == "#+begin_src" then
      has_src = true
    end
  end
  check("directive: begin_src among matches", has_src)
end)

with_buffer({ "regular text" }, function(b)
  local p = dir.cursor_partial(b, 1, 5)
  check("directive: nil on non-`#+` line", p == nil)
end)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("complete_sources_test: PASS")
