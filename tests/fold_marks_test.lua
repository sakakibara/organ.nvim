-- Fold state follows the text through edits: a new heading starts open,
-- a heading's closed state never passes to another heading, and folds the
-- user closed stay closed (organ.fold.marks).
-- Run via: nvim --headless -l tests/fold_marks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
dofile(root .. "/plugin/organ.lua")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("organ").setup({
  org_dir = dir,
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})
vim.cmd("filetype plugin indent on")

local marks = require("organ.fold.marks")

local failures = 0
local function check(label, ok, detail)
  if not ok then
    failures = failures + 1
    io.write("FAIL " .. label .. (detail and (": " .. tostring(detail)) or "") .. "\n")
  end
end

local function pump()
  for _ = 1, 4 do
    vim.wait(10)
  end
end

-- Headless -l never waits for typed input, so SafeState does not fire;
-- run its handler where an idle editor would.
local function idle()
  pump()
  marks.on_safe_state()
end

local BASE =
  { "* TODO A", "body a", "** B", "body b", "* C", "body c", "** D", "body d", "* E", "body e" }
local n = 0
local function open(lines, startup)
  n = n + 1
  local f = dir .. "/case" .. n .. ".org"
  local content = vim.deepcopy(lines or BASE)
  if startup then
    table.insert(content, 1, "#+STARTUP: " .. startup)
  end
  vim.fn.writefile(content, f)
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit " .. vim.fn.fnameescape(f))
  idle()
  return vim.api.nvim_get_current_buf()
end

local function closed(text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l == text then
      return vim.fn.foldclosed(i) == i
    end
  end
  error("no line " .. text)
end

local function line_of(text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if l == text then
      return i
    end
  end
  error("no line " .. text)
end

local function zc(text)
  vim.api.nvim_win_set_cursor(0, { line_of(text), 0 })
  vim.cmd("normal! zc")
  idle()
end

local function keys(k)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "xt", false)
  idle()
end

-- A deeper heading added at the showeverything start is open.
open(BASE, "showeverything")
vim.api.nvim_buf_set_lines(0, 4, 4, false, { "*** N", "body n" })
idle()
check("new deeper heading starts open", not closed("*** N"))

-- A heading inserted above a closed fold does not take its closed state.
open()
zc("* C")
vim.api.nvim_buf_set_lines(0, 4, 4, false, { "* N", "body n" })
idle()
check("heading inserted above a closed fold is open", not closed("* N"))
check("the closed fold below stays closed", closed("* C"))

-- Deleting a subtree above a closed fold keeps it closed.
open()
zc("* C")
vim.api.nvim_buf_set_lines(0, 2, 4, false, {})
idle()
check("closed fold below a deleted subtree stays closed", closed("* C"))

-- Deleting a closed heading does not close the heading after it.
open()
zc("** B")
vim.api.nvim_buf_set_lines(0, 2, 4, false, {})
idle()
check("heading after a deleted closed heading stays open", not closed("* C"))

-- A TODO change on a closed heading keeps it closed.
open()
zc("* C")
require("organ.todo").cycle(0, line_of("* C"))
idle()
check("TODO change keeps the heading closed", closed("* TODO C"))

-- Undoing the delete of a closed heading brings it back closed.
open()
zc("** B")
vim.api.nvim_win_set_cursor(0, { line_of("** B"), 0 })
keys("2dd")
keys("u")
check("undone delete restores the closed heading closed", closed("** B"))

-- Saving, closing a fold, then editing keeps the fold closed.
open()
vim.cmd("silent write")
zc("* C")
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "#+title: x" })
idle()
check("fold closed after a save survives the next edit", closed("* C"))

-- Two windows keep their own fold state through an edit.
open()
vim.cmd("split")
local w2 = vim.api.nvim_get_current_win()
zc("* C")
vim.cmd("wincmd p")
local w1 = vim.api.nvim_get_current_win()
idle()
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "* Z" })
idle()
vim.api.nvim_set_current_win(w2)
check("window that closed C keeps it closed", closed("* C"))
vim.api.nvim_set_current_win(w1)
check("other window keeps C open", not closed("* C"))
vim.cmd("only")

-- Turning folding off and on keeps the closed folds.
open()
zc("* C")
keys("zn")
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "* Z" })
idle()
keys("zN")
idle()
check("folds come back after zn, an edit and zN", closed("* C"))

-- Appending to a folded heading and leaving Insert mode refolds it.
open()
zc("* C")
vim.api.nvim_win_set_cursor(0, { line_of("* C"), 0 })
keys("A x<Esc>")
check("A on a folded heading refolds after Esc", closed("* C x"))

-- A line opened under a folded heading opens it, and a typed heading
-- becomes a fold of its own.
open()
zc("* C")
vim.api.nvim_win_set_cursor(0, { line_of("* C"), 0 })
keys("o** N<Esc>")
check("o under a folded heading opens it", not closed("* C"))
vim.api.nvim_win_set_cursor(0, { line_of("** N"), 0 })
vim.cmd("normal! zc")
check("a heading typed in Insert mode is foldable", closed("** N"))

-- Moving a subtree keeps its folds and its sibling's, and undo restores.
open({ "* A", "body a", "** A1", "a1 body", "", "* B", "body b", "* C", "body c" })
zc("** A1")
zc("* B")
vim.api.nvim_win_set_cursor(0, { line_of("* A"), 0 })
require("organ.structure").move_subtree_down()
idle()
check("moved subtree keeps its nested fold closed", closed("** A1"))
check("sibling it moved past stays closed", closed("* B"))
check(
  "the separator blank stays between them",
  vim.api.nvim_buf_get_lines(0, 0, -1, false)[3] == ""
)
check("cursor follows the moved heading", vim.fn.getline(".") == "* A")
vim.cmd("silent undo")
idle()
check("one undo restores the order", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "* A")
check("and the folds", closed("** A1") and closed("* B"))
require("organ.structure").move_subtree_up({ line = line_of("* B") })
idle()
check("moving up keeps the moved fold closed", closed("* B"))
check("and the one it passed", closed("** A1"))

-- A drawer organ creates starts folded; a pasted subtree keeps the folds
-- it was copied with.
open()
require("organ.property").set(0, line_of("* C"), "X", "1")
idle()
local drawer_line
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if l:match("^%s*:PROPERTIES:%s*$") then
    drawer_line = i
  end
end
check(
  "a PROPERTIES drawer organ creates starts folded",
  drawer_line and vim.fn.foldclosed(drawer_line) == drawer_line
)
check("its heading stays open", not closed("* C"))
open({ "* A", "body a", "** A1", "a1 body", "* B", "body b" })
zc("** A1")
local clipboard = require("organ.clipboard")
clipboard.copy(0, line_of("* A"))
clipboard.paste(0, line_of("* B"))
idle()
local pasted
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if l == "*** A1" then
    pasted = i
  end
end
check("a pasted subtree keeps its closed fold", pasted and vim.fn.foldclosed(pasted) == pasted)
check("the source keeps its own", closed("** A1"))

-- Capture into a file open in a window keeps that window's folds and
-- shows the new entry under its folded parent, its siblings folded.
open({ "* Inbox", "** Old", "old body", "* Other", "other body" })
local inbox_file = vim.api.nvim_buf_get_name(0)
zc("** Old")
zc("* Inbox")
zc("* Other")
local capture = require("organ.capture")
capture.start({
  name = "T",
  target = { kind = "file_headline", path = inbox_file, headline = "Inbox" },
  body = "* New\nnew body",
}, { now = os.time(), prompts = { text = {}, dates = {} } })
local cap = vim.api.nvim_get_current_buf()
vim.cmd("stopinsert")
capture.finalise(cap)
idle()
check(
  "capture leaves the target buffer loaded, not re-read",
  vim.api.nvim_buf_get_name(0) == inbox_file
)
check(
  "the new entry is visible",
  not closed("** New") and vim.fn.foldclosed(line_of("** New")) == -1
)
check("its sibling stays folded", closed("** Old"))
check("an unrelated heading stays folded", closed("* Other"))
check("the file on disk has the entry", vim.tbl_contains(vim.fn.readfile(inbox_file), "** New"))

-- Fold keys typed in one burst with edits are kept: before an edit,
-- after it, and between two edits, and inside a macro.
open()
vim.api.nvim_win_set_cursor(0, { line_of("body c"), 0 })
keys("xzc")
check("xzc keeps C closed", closed("* C"))
open()
vim.api.nvim_win_set_cursor(0, { line_of("body c"), 0 })
keys("zcGx")
check("a fold key before an edit in the burst is kept", closed("* C"))
open()
vim.api.nvim_win_set_cursor(0, { line_of("body c"), 0 })
keys("xggOX<Esc>" .. (line_of("body c") + 1) .. "Gzc")
check("a fold key after a later edit in the burst is kept", closed("* C"))
open()
vim.fn.setreg("q", "xzc")
vim.api.nvim_win_set_cursor(0, { line_of("body c"), 0 })
keys("@q")
check("a macro's fold key is kept", closed("* C"))

-- A fold key where there is no fold reports E490 as Vim does, no trace.
open({ "plain text", "* A", "body a" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("messages clear")
keys("zc")
local msgs = vim.fn.execute("messages")
check("no fold reports E490", msgs:find("E490", 1, true) ~= nil, msgs)
check("without a Lua traceback", not msgs:find("traceback", 1, true), msgs)

-- A heading typed in Insert mode and left with <C-c> (no InsertLeave) is
-- foldable after the next idle point.
open()
vim.api.nvim_win_set_cursor(0, { line_of("body e"), 0 })
keys("o** N<C-c>")
vim.api.nvim_win_set_cursor(0, { line_of("** N"), 0 })
keys("o body n<Esc>")
vim.api.nvim_win_set_cursor(0, { line_of("** N"), 0 })
vim.cmd("silent! normal! zc")
check("a heading typed and left with <C-c> is foldable", closed("** N"))
check("its parent stays open", not closed("* E"))

-- A heading typed over a body line in Replace mode is foldable.
open()
vim.api.nvim_win_set_cursor(0, { line_of("body d"), 0 })
keys("R** X<Esc>")
vim.api.nvim_win_set_cursor(0, { line_of("** X d"), 0 })
vim.cmd("silent! normal! zc")
check("a heading typed in Replace mode is foldable", closed("** X d"))

-- Tab cycles a heading without opening its drawers; SHOW ALL keeps drawer
-- state; S-Tab after another key starts again at OVERVIEW.
local DRAWERS =
  { "* A", ":PROPERTIES:", ":ID: a", ":END:", "body a", "** B", "body b", "* C", "body c" }
local fold = require("organ.fold")
open(DRAWERS, "showall")
require("organ.fold").close_all_drawers(0, 0)
idle()
check("hide_drawers closes the drawer", closed(":PROPERTIES:"))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
for _ = 1, 3 do
  fold.cycle(0, 1)
end
check("Tab to SUBTREE leaves the drawer closed", closed(":PROPERTIES:"))
fold.apply_global_state("show_all", vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
check("SHOW ALL keeps the drawer closed", closed(":PROPERTIES:"))
keys("<S-Tab>")
check("S-Tab goes to OVERVIEW", closed("* A") and closed("* C"))
keys("<S-Tab>")
check("S-Tab again goes to CONTENTS", require("organ.fold.contents").is_active(0))
keys("j<S-Tab>")
check("S-Tab after another key starts at OVERVIEW", closed("* A"))
keys("<S-Tab><S-Tab><S-Tab>")
check("three S-Tabs from OVERVIEW come back to it", closed("* A"))

-- Clearing a sparse tree restores organ's folds and their state.
open()
zc("* C")
local sparse = require("organ.sparse")
sparse.show_todo(0)
idle()
sparse.clear(0)
idle()
check(
  "sparse.clear restores organ's foldexpr",
  vim.wo.foldexpr == "v:lua.require'organ.fold'.foldexpr(v:lnum)",
  vim.wo.foldexpr
)
check("and the closed fold from before", closed("* C"))

vim.fn.delete(dir, "rf")
if failures > 0 then
  os.exit(1)
end
io.write("fold marks ok\n")
