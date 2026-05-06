-- Regression test for the user-reported highlighting bugs:
--   * #+TITLE: value rendered with no highlight
--   * Heading text uncolored (only stars colored)
--   * List bullets / checkboxes uncolored
--   * Bold/italic missing actual bold/italic attribute
--   * Link concealment available behind `emphasis.enabled`
--
-- We assert (a) the relevant @group is registered with sensible
-- defaults, and (b) the tree-sitter query captures the right node
-- type at the expected position.
--
-- Run via: nvim --headless -l tests/highlights_user_bugs_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Load plugin/organ.lua so tree-sitter custom predicates
-- (#org-stars-level?, #org-todo-keyword?) get registered.
dofile(root .. "/plugin/organ.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

-- Register both parsers so tree-sitter queries work in headless.
local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = indexer._inline_parser_path(parser_path) })

-- (a) Highlight group defaults are registered.
local function hl_set(name)
  local h = vim.api.nvim_get_hl(0, { name = name, link = false })
  if next(h) ~= nil then
    return true
  end
  -- Try the linked form.
  local hl = vim.api.nvim_get_hl(0, { name = name })
  return hl.link ~= nil or next(hl) ~= nil
end

check("@org.keyword: registered (used for #+TITLE: lines)", hl_set("@org.keyword"))
check("@org.keyword.name: registered", hl_set("@org.keyword.name"))
check("@org.keyword.value: registered (used for #+TITLE value)", hl_set("@org.keyword.value"))
check("@org.list.bullet: registered", hl_set("@org.list.bullet"))
check("@org.list.checkbox: registered", hl_set("@org.list.checkbox"))
check("@org.heading.title.1: registered (per-level title face)", hl_set("@org.heading.title.1"))
check("@org.heading.title.3: registered (mid-level title face)", hl_set("@org.heading.title.3"))

-- (b) Bold / italic / underline / strikethrough have the attribute on.
local bold_hl = vim.api.nvim_get_hl(0, { name = "@markup.bold", link = false })
check("@markup.bold: bold = true", bold_hl.bold == true, vim.inspect(bold_hl))
local italic_hl = vim.api.nvim_get_hl(0, { name = "@markup.italic", link = false })
check("@markup.italic: italic = true", italic_hl.italic == true, vim.inspect(italic_hl))
local under_hl = vim.api.nvim_get_hl(0, { name = "@markup.underline", link = false })
check("@markup.underline: underline = true", under_hl.underline == true, vim.inspect(under_hl))
local strike_hl = vim.api.nvim_get_hl(0, { name = "@markup.strikethrough", link = false })
check(
  "@markup.strikethrough: strikethrough = true",
  strike_hl.strikethrough == true,
  vim.inspect(strike_hl)
)

-- (c) Tree-sitter query captures the right nodes on a sample buffer.
local sample = {
  "#+TITLE: My title",
  "* Active",
  "** TODO Buy milk",
  "- [ ] todo item",
  "- bullet item",
  "1. ordered item",
}
vim.cmd("enew")
vim.bo.filetype = "org"
vim.api.nvim_buf_set_lines(0, 0, -1, false, sample)
local bufnr = vim.api.nvim_get_current_buf()

local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
check("org parser available", ok_parser, tostring(parser))
if ok_parser and parser then
  parser:parse()
end

-- Run the org/highlights.scm query directly against the parsed tree
-- and gather every (capture_name, range) tuple — bypasses the
-- highlighter (which needs `:syntax on` etc.) so we can assert the
-- query alone.
local query = vim.treesitter.query.parse(
  "org",
  table.concat(vim.fn.readfile(root .. "/queries/org/highlights.scm"), "\n")
)
local tree = parser:parse()[1]

local function captures_at(row, col)
  local out = {}
  for id, node in query:iter_captures(tree:root(), bufnr, 0, -1) do
    local sr, sc, er, ec = node:range()
    local in_range = (sr < row or (sr == row and sc <= col))
      and (er > row or (er == row and ec > col))
    if in_range then
      out[#out + 1] = "@" .. query.captures[id]
    end
  end
  return out
end
local function any_capture_starts(caps, prefix)
  for _, c in ipairs(caps) do
    if c == prefix or c:sub(1, #prefix + 1) == prefix .. "." then
      return true
    end
  end
  return false
end

-- #+TITLE: My title — value byte should hit @org.keyword.value.
local caps_title_value = captures_at(0, 12) -- inside "My title"
check(
  "`#+TITLE: …` value bytes captured under @org.keyword*",
  any_capture_starts(caps_title_value, "@org.keyword"),
  "caps: " .. vim.inspect(caps_title_value)
)

-- "* Active" — title text byte (col 2 = inside "Active") should hit
-- @org.heading.title.1.
local caps_h1_title = captures_at(1, 2)
check(
  "level-1 heading title text captured under @org.heading.title.1",
  vim.tbl_contains(caps_h1_title, "@org.heading.title.1"),
  "caps: " .. vim.inspect(caps_h1_title)
)

-- "** TODO Buy milk" — title bytes after TODO state.  The grammar
-- excludes the `TODO` token from `title:`, so col 8 ("Buy milk")
-- lands on @org.heading.title.2.
local caps_h2_title = captures_at(2, 9)
check(
  "level-2 heading title text captured under @org.heading.title.2",
  vim.tbl_contains(caps_h2_title, "@org.heading.title.2"),
  "caps: " .. vim.inspect(caps_h2_title)
)

-- List bullet — col 0 of "- [ ] …" should hit @org.list.bullet.
local caps_bullet = captures_at(3, 0)
check(
  "list bullet `- ` captured under @org.list.bullet",
  vim.tbl_contains(caps_bullet, "@org.list.bullet"),
  "caps: " .. vim.inspect(caps_bullet)
)

-- Checkbox `[ ]` — col 2 of "- [ ] …" should hit @org.list.checkbox.
local caps_check = captures_at(3, 2)
check(
  "checkbox `[ ]` captured under @org.list.checkbox",
  vim.tbl_contains(caps_check, "@org.list.checkbox"),
  "caps: " .. vim.inspect(caps_check)
)

-- Numbered list bullet — col 0 of "1. …" should also hit
-- @org.list.bullet (same node, ordered form).
local caps_num = captures_at(5, 0)
check(
  "ordered list bullet `1.` captured under @org.list.bullet",
  vim.tbl_contains(caps_num, "@org.list.bullet"),
  "caps: " .. vim.inspect(caps_num)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("highlights_user_bugs_test: PASS")
