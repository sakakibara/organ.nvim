-- Hover preview: resolve a link to its target headline + render preview.
-- Run via: nvim --headless -l tests/hover_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname() .. "/hover"
vim.fn.mkdir(tmp, "p")
local fpath = tmp .. "/x.org"
vim.fn.writefile({
  "* TODO Target headline",
  "  First body line.",
  "  Second body line.",
  "  Third body line.",
  "* Next sibling",
  "  This should NOT appear in the preview.",
}, fpath)

package.loaded["organ.query"] = {
  agenda = function()
    return {}
  end,
  headlines = function(filt)
    if filt and filt.id == "the-id" then
      return {
        {
          id = "the-id",
          title = "Target headline",
          file_path = fpath,
          line_start = 0,
          todo_state = "TODO",
        },
      }
    end
    if filt and filt.title == "Target headline" then
      return {
        {
          id = "the-id",
          title = "Target headline",
          file_path = fpath,
          line_start = 0,
          todo_state = "TODO",
        },
      }
    end
    return {}
  end,
  files = function()
    return {}
  end,
  links = function()
    return {}
  end,
}

require("organ").setup({
  org_dir = tmp,
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local hover = require("organ.hover")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- 1. Resolve id: link.
local row_id = hover.resolve("id:the-id")
check("resolve id:the-id → row", row_id and row_id.title == "Target headline")

-- 2. Resolve *Title link.
local row_title = hover.resolve("*Target headline")
check("resolve *Target headline → row", row_title and row_title.title == "Target headline")

-- 3. Resolve unknown id → nil.
local nope = hover.resolve("id:nonexistent")
check("resolve unknown id returns nil", nope == nil)

-- 4. preview_lines: contains title + body excerpt + stops at next headline.
local lines = hover.preview_lines(row_id)
local joined = table.concat(lines, "\n")
check("preview_lines includes title", joined:find("Target headline", 1, true))
check("preview_lines includes body", joined:find("First body line.", 1, true))
check("preview_lines stops before next headline", not joined:find("Next sibling", 1, true))

-- 5. End-to-end: open() on a buffer with cursor on a link returns true.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "Some text and [[id:the-id][see target]] continues.",
})
vim.bo[b].filetype = "org"
vim.api.nvim_set_current_buf(b)
-- Cursor on column 20 (inside the link).
vim.api.nvim_win_set_cursor(0, { 1, 20 })
local opened = hover.open()
check("open() returns true on a link", opened == true)

-- 6. open() returns false when not on a link.
vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- col 2 is "Some" — not in link
local opened2 = hover.open()
check("open() returns false off a link", opened2 == false)

-- 7. Link with description still resolved.
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "Look [[*Target headline][here]] please.",
})
vim.api.nvim_win_set_cursor(0, { 1, 10 })
local opened3 = hover.open()
check("open() handles [[*Title][desc]] form", opened3 == true)

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("hover_test: PASS")
