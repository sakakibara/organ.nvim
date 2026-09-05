-- organ.emphasize: `:Org emphasize` (Emacs org-emphasize, C-c C-x C-f).
-- The expected buffers below are what real Emacs 30 / org 9.7.11
-- produces for the same region and marker, checked with
--   emacs --batch -Q -l org --eval '(org-emphasize ?*)'
-- over an active region before it was encoded here.
--
-- Run via: nvim --headless -l tests/emphasize_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local emphasize = require("organ.emphasize")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function mkbuf(text)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { text })
  return b
end

-- Emphasize the byte span [s, e] and compare the whole line.
local function span(label, text, s, e, marker, want)
  local b = mkbuf(text)
  local err = emphasize.span(b, 1, s, e, marker)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)[1]
  check(label, err == nil and got == want, err or ("[" .. tostring(got) .. "]"))
end

-- 1. A plain region takes the marker.
span("a word becomes bold", "hello world here", 7, 11, "*", "hello *world* here")

-- 2. Re-applying the same marker to an already-bold region is a no-op,
-- because the existing pair is peeled off before the new one is added.
span("re-bolding a bold region keeps it bold", "a *bold* b", 3, 8, "*", "a *bold* b")

-- 3. A different marker replaces rather than nests.
span("a different marker replaces the old one", "a *bold* b", 3, 8, "/", "a /bold/ b")

-- 4. `remove` is Emacs's SPC at the marker prompt: it strips emphasis.
span("remove strips the markers", "a *bold* b", 3, 8, "remove", "a bold b")

-- 5. With an empty span, Emacs inserts the bare pair and pads either
-- side whose neighbour would swallow the marker.
span("an empty span inserts the pair mid-word", "hello world", 9, 8, "*", "hello wo ** rld")
span("no padding is added at the start of a line", "hello world", 1, 0, "*", "** hello world")

-- 6. Padding is only added where the neighbour is outside org's
-- pre / post character classes.
span("a space neighbour needs no padding", "a b c", 3, 3, "*", "a *b* c")
span("punctuation after needs no padding", "a b, c", 3, 3, "*", "a *b*, c")

-- 7. The cursor lands between the markers on an empty span, and after
-- the emphasised text otherwise.
do
  local b = mkbuf("hello world")
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  emphasize.span(b, 1, 1, 0, "*")
  check("the cursor sits between the bare markers", vim.api.nvim_win_get_cursor(0)[2] == 1)
end

-- 8. An unknown marker refuses and leaves the line alone.
do
  local b = mkbuf("hello world here")
  local err = emphasize.span(b, 1, 7, 11, "%")
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)[1]
  check(
    "an unknown marker refuses",
    err == "no such emphasis marker: %" and got == "hello world here",
    tostring(err) .. " / " .. got
  )
end
do
  local marker, why = emphasize.resolve_marker(nil)
  check("no marker at all refuses", marker == nil and why == "no emphasis marker given")
end

-- 9. Word at cursor when there is no selection (organ's addition over
-- Emacs, which would insert bare markers there).  A word already
-- wrapped in a marker keeps its single pair.
local function at_cursor(label, text, col, marker, want)
  local b = mkbuf(text)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, { 1, col })
  local err = emphasize.dispatch(marker, false)
  local got = vim.api.nvim_buf_get_lines(b, 0, -1, false)[1]
  check(label, err == nil and got == want, err or ("[" .. tostring(got) .. "]"))
end
at_cursor("the word at the cursor is emphasised", "hello world here", 7, "*", "hello *world* here")
at_cursor("an emphasised word does not nest", "a *bold* b", 4, "*", "a *bold* b")
at_cursor("remove strips the word at the cursor", "a *bold* b", 4, "remove", "a bold b")
-- Off a word, Emacs's own behaviour: the bare pair with the cursor
-- between them.
at_cursor("off a word, the bare pair is inserted", "a  b", 1, "*", "a **  b")

if fails > 0 then
  print(("\n%d check(s) failed"):format(fails))
  os.exit(1)
end
print("\nemphasize: all checks passed")
