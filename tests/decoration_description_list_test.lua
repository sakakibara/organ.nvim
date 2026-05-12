-- Unit test for the description_list provider via organ.decoration.
--
-- Verifies that loading organ.description_list registers a decoration
-- provider, the per-buffer row cache is built from on_lines via the
-- tree-sitter list_item / paragraph walk, and the on_line dispatcher
-- emits term + `::` separator extmarks for matching rows only.
-- Ephemeral marks placed by on_line aren't visible to
-- nvim_buf_get_extmarks outside the real frame-rendering context, so
-- the assertions go through _apply, which shares build_cache with
-- on_lines but writes non-ephemeral marks.
--
-- Run via: nvim --headless -l tests/decoration_description_list_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
-- Loading the module triggers its top-level decoration.register({...}).
require("organ.description_list")

local decoration = require("organ.decoration")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local providers, _ = decoration._providers()
check("description_list provider registered", providers.description_list ~= nil)
check("provider exposes ns", providers.description_list and providers.description_list.ns ~= nil)
check(
  "provider exposes on_lines + on_line",
  providers.description_list
    and type(providers.description_list.on_lines) == "function"
    and type(providers.description_list.on_line) == "function"
)

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Heading",
  "- term1 :: definition for term1.",
  "  plain continuation line.",
  "- term2 :: another definition.",
})

decoration.attach(bufnr)

-- _apply rebuilds the cache + writes non-ephemeral marks so
-- nvim_buf_get_extmarks can see them.  The ephemeral path is exercised
-- by the real decoration-provider callback at frame time.
require("organ.description_list")._apply(bufnr)

local NS = vim.api.nvim_create_namespace("organ_description_list")
local marks_term1 = vim.api.nvim_buf_get_extmarks(
  bufnr,
  NS,
  { 1, 0 },
  { 1, -1 },
  { details = true }
)
local marks_cont = vim.api.nvim_buf_get_extmarks(bufnr, NS, { 2, 0 }, { 2, -1 }, { details = true })
local marks_term2 = vim.api.nvim_buf_get_extmarks(
  bufnr,
  NS,
  { 3, 0 },
  { 3, -1 },
  { details = true }
)

-- Each matching row gets two marks: term + `::` separator.
check(
  "term row 1 has two marks (term + separator)",
  #marks_term1 == 2,
  "got " .. #marks_term1 .. ": " .. vim.inspect(marks_term1)
)
check(
  "continuation row has no mark",
  #marks_cont == 0,
  "got " .. #marks_cont .. ": " .. vim.inspect(marks_cont)
)
check(
  "term row 3 has two marks (term + separator)",
  #marks_term2 == 2,
  "got " .. #marks_term2 .. ": " .. vim.inspect(marks_term2)
)

-- Verify the highlight groups are the ones the old module used.
local function has_hl(marks, hl)
  for _, m in ipairs(marks) do
    if m[4] and m[4].hl_group == hl then
      return true
    end
  end
  return false
end
check("term row 1 includes @org.list.term mark", has_hl(marks_term1, "@org.list.term"))
check(
  "term row 1 includes @org.list.term_separator mark",
  has_hl(marks_term1, "@org.list.term_separator")
)

-- A line WITHOUT `term ::` should not produce marks even if it's a
-- list item, and `https://` style colons must not false-positive.
local bufnr2 = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr2].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr2, 0, -1, false, {
  "- plain list item without separator",
  "- see https://example.com for details",
})
decoration.attach(bufnr2)
require("organ.description_list")._apply(bufnr2)
local marks_plain = vim.api.nvim_buf_get_extmarks(
  bufnr2,
  NS,
  { 0, 0 },
  { 0, -1 },
  { details = true }
)
local marks_url = vim.api.nvim_buf_get_extmarks(bufnr2, NS, { 1, 0 }, { 1, -1 }, { details = true })
check("plain list item has no marks", #marks_plain == 0)
check("https:// list item has no marks (no `::` surrounded by whitespace)", #marks_url == 0)

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.api.nvim_buf_delete(bufnr2, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_description_list_test: PASS")
os.exit(0)
