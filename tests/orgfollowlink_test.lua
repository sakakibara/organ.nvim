-- :Org follow_link opens the id target of the link under cursor.
-- Run via: nvim --headless -l tests/orgfollowlink_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/fl.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
local fixture = org_dir .. "/05.org"
vim.fn.system({ "cp", root .. "/tests/fixtures/05-links.org", fixture })

require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  mtime_skip = false,
})
require("organ").scan_blocking(org_dir, 5000)

assert(vim.api.nvim_get_commands({}).Org, ":Org not registered")
assert(
  require("organ").cmd("follow_link"),
  "subcommand `follow_link` not registered in :Org dispatcher"
)

vim.cmd("edit " .. vim.fn.fnameescape(fixture))
vim.bo.filetype = "org"

local target_line
for lnum, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if line:find("id:beta-id", 1, true) then
    target_line = lnum
    break
  end
end
assert(target_line, "target line not found")
local col = vim.api.nvim_buf_get_lines(0, target_line - 1, target_line, false)[1]:find("beta%-id")
vim.api.nvim_win_set_cursor(0, { target_line, col })

vim.cmd("Org follow_link")

local beta = require("organ.query").get_by_id("beta-id")
assert(beta, "beta should be indexed")
local pos = vim.api.nvim_win_get_cursor(0)
assert(
  pos[1] == beta.line_start + 1,
  string.format("cursor at line %d, expected %d", pos[1], beta.line_start + 1)
)

-- Anchor link: [[file:./other.org::*Sub Heading]] in the source buffer
-- should open other.org with cursor on '* Sub Heading'.
do
  local other_path = org_dir .. "/other.org"
  local f = assert(io.open(other_path, "w"))
  f:write([=[* Top
  body
* Sub Heading
  more body
]=])
  f:close()
  -- Reindex the new file (it lives under org_dir; scan_blocking handles it).
  require("organ").scan_blocking(org_dir, 5000)

  -- Re-open the source fixture and append a line with the anchor link.
  vim.cmd("edit " .. vim.fn.fnameescape(fixture))
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  table.insert(lines, "See [[file:./other.org::*Sub Heading]] for details.")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.filetype = "org"
  -- Force a fresh tree-sitter parse so the new link is recognised.
  local ok_p, parser = pcall(vim.treesitter.get_parser, 0, "org")
  if ok_p and parser then
    parser:parse(true)
  end

  -- Position cursor on the new link line, on the 'file:' text.
  local anchor_line = #lines
  local txt = vim.api.nvim_buf_get_lines(0, anchor_line - 1, anchor_line, false)[1]
  local col = txt:find("file:")
  assert(col, "anchor link not present in buffer")
  vim.api.nvim_win_set_cursor(0, { anchor_line, col })

  vim.cmd("Org follow_link")

  local cur_path = vim.api.nvim_buf_get_name(0)
  assert(cur_path:match("/other%.org$"), "anchor link should open other.org; got " .. cur_path)
  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local hit = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
  assert(
    hit == "* Sub Heading",
    "expected cursor on '* Sub Heading'; got line " .. cur_line .. " = " .. tostring(hit)
  )
end

-- Property-value link: [[ROAM_REFS:https://example.com]] in the buffer
-- should jump to the headline whose :ROAM_REFS: property matches.
do
  -- Add a headline with ROAM_REFS to the existing fixture.
  vim.cmd("edit " .. vim.fn.fnameescape(fixture))
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  table.insert(lines, "")
  table.insert(lines, "* Ref-bearing")
  table.insert(lines, "  :PROPERTIES:")
  table.insert(lines, "  :ROAM_REFS: https://prop.example.com")
  table.insert(lines, "  :END:")
  table.insert(lines, "  See [[ROAM_REFS:https://prop.example.com]] for the original.")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.cmd("write")
  require("organ").scan_blocking(org_dir, 5000)

  -- Re-open + force fresh parse.
  vim.cmd("edit " .. vim.fn.fnameescape(fixture))
  vim.bo.filetype = "org"
  local ok_p, parser = pcall(vim.treesitter.get_parser, 0, "org")
  if ok_p and parser then
    parser:parse(true)
  end

  -- Position cursor on the link line at the link target text.
  local link_line
  for lnum, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l:find("ROAM_REFS:https", 1, true) then
      link_line = lnum
      break
    end
  end
  assert(link_line, "link line not found")
  local txt = vim.api.nvim_buf_get_lines(0, link_line - 1, link_line, false)[1]
  local col = txt:find("ROAM_REFS:https")
  vim.api.nvim_win_set_cursor(0, { link_line, col })

  vim.cmd("Org follow_link")

  local cur_line = vim.api.nvim_win_get_cursor(0)[1]
  local hit = vim.api.nvim_buf_get_lines(0, cur_line - 1, cur_line, false)[1]
  assert(
    hit == "* Ref-bearing",
    "expected cursor on '* Ref-bearing'; got line " .. cur_line .. " = " .. tostring(hit)
  )
end

vim.fn.delete(tmp, "rf")
io.write("OrgFollowLink ok\n")
os.exit(0)
