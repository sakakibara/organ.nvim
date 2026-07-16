-- meta_return on description-list items and the split-at-point knobs.
--
-- Description items get an Emacs-parity skeleton: M-RET on
-- `- term :: def` inserts `-  :: ` with the cursor in the term slot
-- (probed against Emacs 30.2).
--
-- Splitting: `meta_return.split_item` / `meta_return.split_headline`
-- (both default false) enable the Emacs behavior of splitting the
-- item/headline text at the cursor.  Probed rules: the tail becomes a
-- new sibling right below the cursor line (children then follow the
-- tail); a checkbox stays on the head, the tail is plain; ordered
-- tails take the next number and the rest renumber; a description
-- tail is `-  :: <remainder>` with the cursor in the term slot; a
-- headline tail is `<stars> <remainder>`.
--
-- Run via: nvim --headless -l tests/meta_return_desc_split_test.lua

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

local meta_return = require("organ.meta_return")
local buf_config = require("organ.buf_config")

local function buf_with(lines, cfg)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if cfg then
    buf_config.set_table(b, { meta_return = cfg })
  end
  return b
end
local function lines_of(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function eq(a, b)
  return vim.deep_equal(a, b)
end
local function detail(got)
  return "got:\n     " .. table.concat(got, "\n     ")
end
local function dispatch_at(line, col)
  vim.api.nvim_win_set_cursor(0, { line, col })
  meta_return.dispatch({ enter_insert = false })
end

-- Description skeleton at end of line.
do
  local b = buf_with({ "- term :: def" })
  dispatch_at(1, 12)
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check(
    "desc item M-RET inserts term-slot skeleton",
    eq(got, { "- term :: def", "-  :: " }),
    detail(got)
  )
  check("desc skeleton cursor in term slot", pos[1] == 2 and pos[2] == 2, vim.inspect(pos))
end

-- Indented `+` description item keeps indent and bullet.
do
  local b = buf_with({ "  + key :: value" })
  dispatch_at(1, 15)
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check(
    "indented + desc item keeps indent and bullet",
    eq(got, { "  + key :: value", "  +  :: " }),
    detail(got)
  )
  check("indented desc cursor in term slot", pos[1] == 2 and pos[2] == 4, vim.inspect(pos))
end

-- Ordered items are never description items.
do
  local b = buf_with({ "1. a :: b" })
  dispatch_at(1, 8)
  local got = lines_of(b)
  check("ordered item with :: stays plain", eq(got, { "1. a :: b", "2. " }), detail(got))
end

-- Splitting is off by default: mid-text M-RET appends an empty sibling.
do
  local b = buf_with({ "- alpha" })
  dispatch_at(1, 4)
  local got = lines_of(b)
  check("split_item off: no mid-text split", eq(got, { "- alpha", "- " }), detail(got))
end

-- split_item: plain item splits at the cursor.
do
  local b = buf_with({ "- alpha" }, { split_item = true })
  dispatch_at(1, 4)
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check("split_item: plain item splits", eq(got, { "- al", "- pha" }), detail(got))
  check("split cursor at tail content start", pos[1] == 2 and pos[2] == 2, vim.inspect(pos))
end

-- split_item: children follow the tail.
do
  local b = buf_with({ "- alpha", "  - child" }, { split_item = true })
  dispatch_at(1, 4)
  local got = lines_of(b)
  check(
    "split_item: children follow the tail",
    eq(got, { "- al", "- pha", "  - child" }),
    detail(got)
  )
end

-- split_item: checkbox stays on the head, tail is plain.
do
  local b = buf_with({ "- [ ] alpha" }, { split_item = true })
  dispatch_at(1, 8)
  local got = lines_of(b)
  check("split_item: checkbox stays on head", eq(got, { "- [ ] al", "- pha" }), detail(got))
end

-- split_item: ordered tail renumbers the rest.
do
  local b = buf_with({ "1. alpha", "2. beta" }, { split_item = true })
  dispatch_at(1, 5)
  local got = lines_of(b)
  check(
    "split_item: ordered tail renumbers",
    eq(got, { "1. al", "2. pha", "3. beta" }),
    detail(got)
  )
end

-- split_item: description tail keeps the :: skeleton.
do
  local b = buf_with({ "- term :: definition" }, { split_item = true })
  dispatch_at(1, 13)
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check(
    "split_item: desc tail keeps :: skeleton",
    eq(got, { "- term :: def", "-  :: inition" }),
    detail(got)
  )
  check("desc split cursor in term slot", pos[1] == 2 and pos[2] == 2, vim.inspect(pos))
end

-- split_item: the split point is BEFORE the cursor character (the `i`
-- convention, matching Emacs point semantics), so a cursor sitting on
-- the last char still splits it off ...
do
  local b = buf_with({ "- alpha" }, { split_item = true })
  dispatch_at(1, 6)
  local got = lines_of(b)
  check(
    "split_item: cursor on last char splits before it",
    eq(got, { "- alph", "- a" }),
    detail(got)
  )
end

-- ... while a cursor past the last char (insert mode M-RET at end of
-- line) appends an empty sibling.
do
  local b = buf_with({ "- alpha" }, { split_item = true })
  vim.wo.virtualedit = "onemore"
  dispatch_at(1, 7)
  vim.wo.virtualedit = ""
  local got = lines_of(b)
  check(
    "split_item: cursor past EOL keeps append behavior",
    eq(got, { "- alpha", "- " }),
    detail(got)
  )
end

-- split_item: cursor at content start keeps append behavior.
do
  local b = buf_with({ "- alpha" }, { split_item = true })
  dispatch_at(1, 2)
  local got = lines_of(b)
  check(
    "split_item: content-start cursor keeps append behavior",
    eq(got, { "- alpha", "- " }),
    detail(got)
  )
end

-- split_headline: title splits; body and children follow the tail.
do
  local b = buf_with({ "* Headline", "body", "** child", "* Next" }, { split_headline = true })
  dispatch_at(1, 5)
  local got = lines_of(b)
  local pos = vim.api.nvim_win_get_cursor(0)
  check(
    "split_headline: title splits at cursor",
    eq(got, { "* Hea", "* dline", "body", "** child", "* Next" }),
    detail(got)
  )
  check("headline split cursor on tail", pos[1] == 2, vim.inspect(pos))
end

-- split_headline off: mid-title M-RET keeps append-at-subtree-end.
do
  local b = buf_with({ "* Headline", "body", "* Next" }, { split_item = true })
  dispatch_at(1, 5)
  local got = lines_of(b)
  check(
    "split_headline off: mid-title keeps append behavior",
    eq(got, { "* Headline", "body", "* ", "* Next" }),
    detail(got)
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("meta_return_desc_split_test: PASS")
