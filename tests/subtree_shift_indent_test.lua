-- Normal-mode `>>`/`<<`: demote/promote the subtree on a headline line,
-- but fall through to Vim's native indent off a headline.
-- Run via: nvim --headless -l tests/subtree_shift_indent_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
-- Register the :Org subcommand tree so dispatch() can resolve `demote`.
dofile(root .. "/plugin/organ.lua")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  vim.api.nvim_set_current_buf(b)
  -- Edit with folds open (the realistic case when changing a planning
  -- line); a closed fold would make native >> shift the whole fold.
  vim.wo.foldenable = false
  require("organ.ftplugin.subtree").attach(b)
  return b
end

local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function line1(b)
  return vim.api.nvim_buf_get_lines(b, 0, 1, false)[1]
end

-- On the headline line: >> demotes the subtree.
do
  local b = mkbuf({ "* Head", "DEADLINE: <2026-06-16 Tue>", "body" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed(">>")
  check(line1(b) == "** Head", "headline: >> demotes the subtree")
end

-- On a DEADLINE planning line: >> indents the line natively; headline untouched.
do
  local b = mkbuf({ "* Head", "DEADLINE: <2026-06-16 Tue>", "body" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  feed(">>")
  check(line1(b) == "* Head", "deadline: >> does NOT demote the headline")
  local l2 = vim.api.nvim_buf_get_lines(b, 1, 2, false)[1]
  check(l2:match("^%s+DEADLINE"), "deadline: >> applies native indent to the line")
end

-- On a body line: << is native dedent, not a promote.
do
  local b = mkbuf({ "* Head", "  body" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  feed("<<")
  check(line1(b) == "* Head", "body: << does NOT promote the headline")
  check(
    vim.api.nvim_buf_get_lines(b, 1, 2, false)[1] == "body",
    "body: << dedents the line natively"
  )
end

print("ALL PASS: subtree_shift_indent")
