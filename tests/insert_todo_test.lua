-- insert_todo (Emacs M-S-RET, org-insert-todo-heading): like
-- meta_return but the new element is a TODO heading / unchecked
-- checkbox item.  Probed against Emacs 30.2:
--   * headline / body   -> new sibling heading prefixed with the FIRST
--                          ACTIVE keyword of the current entry's TODO
--                          sequence (never a copy of the current
--                          state: on `* DONE x` it inserts `* TODO `,
--                          on `* NEXT x` under `#+TODO: NEXT WAIT |
--                          FIN` it inserts `* NEXT `).
--   * list item         -> `- [ ] ` sibling, always unchecked, even
--                          from a plain or `[X]` item; ordered lists
--                          renumber; a description item keeps the
--                          ` :: ` skeleton after the checkbox.
-- Table rows and preamble lines fall back to the heading behavior
-- (organ's respect-content convention; Emacs splits the line there,
-- which organ's M-RET already deliberately avoids).
--
-- Run via: nvim --headless -l tests/insert_todo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

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

local meta_return = require("organ.meta_return")
local buf_config = require("organ.buf_config")

local function org_buf(lines, cfg)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  vim.cmd("doautocmd FileType")
  if cfg then
    buf_config.set_table(b, { meta_return = cfg })
  end
  return b
end
local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end
local function eq(a, b)
  return vim.deep_equal(a, b)
end
local function detail(got)
  return "got:\n     " .. table.concat(got, "\n     ")
end
local function todo_at(line, col)
  vim.api.nvim_win_set_cursor(0, { line, col })
  meta_return.dispatch({ enter_insert = false, todo = true })
end

-- Plain headline: TODO sibling at the end of the subtree.
do
  local b = org_buf({ "* Alpha", "body", "* Next" })
  todo_at(1, 0)
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check(
    "headline: TODO sibling after subtree body",
    eq(got, { "* Alpha", "body", "* TODO ", "* Next" }),
    detail(got)
  )
  -- col clamps to the last char in normal mode; insert entry appends
  -- at EOL, i.e. right after the keyword.
  check("headline: cursor at end of prefix", pos[1] == 3 and pos[2] == 6, vim.inspect(pos))
end

-- DONE headline: keyword is the sequence head, not the current state.
do
  local b = org_buf({ "* DONE Alpha" })
  todo_at(1, 0)
  local got = lines_of(b)
  check("DONE headline inserts TODO", eq(got, { "* DONE Alpha", "* TODO " }), detail(got))
end

-- Buffer-local #+TODO: sequence: head of the entry's sequence wins.
do
  local b = org_buf({ "#+TODO: NEXT WAIT | FIN", "* NEXT Alpha" })
  todo_at(2, 0)
  local got = lines_of(b)
  check(
    "buffer #+TODO sequence head used",
    eq(got, { "#+TODO: NEXT WAIT | FIN", "* NEXT Alpha", "* NEXT " }),
    detail(got)
  )
end

-- Multiple sequences: the current entry's sequence is chosen.
do
  local b = org_buf({
    "#+TODO: TODO | DONE",
    "#+TODO: BUG WIP | FIXED",
    "* BUG crash",
  })
  todo_at(3, 0)
  local got = lines_of(b)
  check(
    "multi-sequence: entry's own sequence head",
    eq(got, {
      "#+TODO: TODO | DONE",
      "#+TODO: BUG WIP | FIXED",
      "* BUG crash",
      "* BUG ",
    }),
    detail(got)
  )
end

-- Plain item gains an unchecked checkbox.
do
  local b = org_buf({ "- alpha", "- beta" })
  todo_at(1, 0)
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check("plain item: checkbox sibling", eq(got, { "- alpha", "- [ ] ", "- beta" }), detail(got))
  check("item: cursor at end of prefix", pos[1] == 2 and pos[2] == 5, vim.inspect(pos))
end

-- Checked item still yields an unchecked sibling.
do
  local b = org_buf({ "- [X] alpha" })
  todo_at(1, 0)
  local got = lines_of(b)
  check("[X] item: unchecked sibling", eq(got, { "- [X] alpha", "- [ ] " }), detail(got))
end

-- Ordered checkbox list renumbers.
do
  local b = org_buf({ "1. [ ] alpha", "2. [ ] beta" })
  todo_at(1, 0)
  local got = lines_of(b)
  check(
    "ordered checkbox list renumbers",
    eq(got, { "1. [ ] alpha", "2. [ ] ", "3. [ ] beta" }),
    detail(got)
  )
end

-- Description item keeps the :: skeleton after the checkbox.
do
  local b = org_buf({ "- term :: def" })
  todo_at(1, 0)
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check(
    "desc item: checkbox + :: skeleton",
    eq(got, { "- term :: def", "- [ ]  :: " }),
    detail(got)
  )
  check("desc item: cursor in term slot", pos[1] == 2 and pos[2] == 6, vim.inspect(pos))
end

-- Body line: TODO heading at the enclosing level after the subtree.
do
  local b = org_buf({ "* Alpha", "body here", "* Next" })
  todo_at(2, 3)
  local got = lines_of(b)
  check(
    "body line: TODO heading appended to subtree",
    eq(got, { "* Alpha", "body here", "* TODO ", "* Next" }),
    detail(got)
  )
end

-- Table row falls back to the heading behavior (no table split).
do
  local b = org_buf({ "* Alpha", "| a | b |", "* Next" })
  todo_at(2, 2)
  local got = lines_of(b)
  check(
    "table row: TODO heading, table intact",
    eq(got, { "* Alpha", "| a | b |", "* TODO ", "* Next" }),
    detail(got)
  )
end

-- No headings anywhere: start outlining with a TODO heading.
do
  local b = org_buf({ "just prose" })
  todo_at(1, 3)
  local got = lines_of(b)
  check(
    "no-heading buffer: TODO heading appended",
    eq(got, { "just prose", "* TODO " }),
    detail(got)
  )
end

-- split_item composes: mid-text M-S-RET tail keeps the checkbox prefix.
do
  local b = org_buf({ "- [ ] alpha" }, { split_item = true })
  todo_at(1, 8)
  local got = lines_of(b)
  check(
    "split_item + todo: tail gets unchecked checkbox",
    eq(got, { "- [ ] al", "- [ ] pha" }),
    detail(got)
  )
end

-- <M-S-CR> keymap drives it.
do
  local b = org_buf({ "* Alpha", "* Next" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed("<M-S-CR>")
  local got = lines_of(b)
  check("<M-S-CR> inserts TODO sibling", eq(got, { "* Alpha", "* TODO ", "* Next" }), detail(got))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("insert_todo_test: PASS")
