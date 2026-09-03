-- CONTENTS is per-window state keyed by winid.  Two paths leave that
-- state pointing at a window that no longer shows the buffer:
--
--   1. `:e other.org` in the CONTENTS window while the org buffer is
--      still visible in a second split (BufWinLeave does not fire).
--   2. Closing the CONTENTS window (`:close`) when it was the last
--      window in CONTENTS for the buffer.
--
-- Contract: is_active(winid) is true only while that window still
-- shows the buffer it entered CONTENTS for; the buffer-level state
-- (extmarks, augroup, `za`/`zc`/... overrides) is torn down once no
-- window is left in CONTENTS for the buffer; and a window that later
-- re-shows the buffer does not inherit CONTENTS' raised conceal
-- options.
--
-- Run via: nvim --headless -l tests/fold_contents_stale_window_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fold = require("organ.fold")
local contents = require("organ.fold.contents")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function edit_org(path)
  vim.cmd("edit " .. path)
  if vim.bo.filetype ~= "org" then
    vim.bo.filetype = "org"
  end
  vim.wait(50)
  return vim.api.nvim_get_current_buf()
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "* A1", "body a1", "** A2", "body a2" }, dir .. "/a.org")
vim.fn.writefile({ "* B1", "body b1", "* B2", "body b2" }, dir .. "/b.org")

-- Scenario 1: a.org in two splits, CONTENTS in W2, then `:e b.org` in W2.
local A = edit_org(dir .. "/a.org")
local W1 = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local W2 = vim.api.nvim_get_current_win()
fold.apply_content(W2, A)
check("W2 in CONTENTS for a.org", contents.is_active(W2) == true)

local B = edit_org(dir .. "/b.org")
check("W2 shows b.org", vim.api.nvim_win_get_buf(W2) == B)
check(
  "W2 no longer in CONTENTS after :e b.org",
  contents.is_active(W2) == false,
  "is_active(W2) = " .. tostring(contents.is_active(W2))
)
check(
  "a.org has no CONTENTS window left",
  contents.is_active(A) == false,
  "is_active(A) = " .. tostring(contents.is_active(A))
)
check(
  "detect_global_state(W2, b.org) is show_all",
  fold.detect_global_state(W2, B) == "show_all",
  "got " .. tostring(fold.detect_global_state(W2, B))
)

vim.api.nvim_win_set_cursor(W2, { 1, 0 })
local handled = fold.cycle(B, 1)
check(
  "Tab on * B1 folds its subtree in W2",
  handled == true and vim.fn.foldclosed(1) == 1,
  "handled=" .. tostring(handled) .. " foldclosed(1)=" .. vim.fn.foldclosed(1)
)
vim.cmd("silent! %foldopen!")
fold.cycle_global(B)
check(
  "S-Tab from show_all reaches overview (foldlevel 0)",
  vim.wo[W2].foldlevel == 0,
  "foldlevel=" .. vim.wo[W2].foldlevel
)

-- W2 re-shows a.org: the conceal options CONTENTS raised must not
-- come back with the buffer.
vim.cmd("buffer " .. A)
vim.wait(50)
check(
  "W2 back on a.org: conceallevel not raised",
  vim.wo[W2].conceallevel == 0,
  "conceallevel=" .. vim.wo[W2].conceallevel
)
check(
  "W2 back on a.org: concealcursor not raised",
  vim.wo[W2].concealcursor == "",
  "concealcursor=" .. vim.wo[W2].concealcursor
)
check("W2 back on a.org: not in CONTENTS", contents.is_active(W2) == false)
fold.apply_content(W2, A)
check(
  "W2 can enter CONTENTS for a.org again",
  contents.is_active(W2) == true and contents.heading_concealed(A, 1) == true,
  "is_active="
    .. tostring(contents.is_active(W2))
    .. " concealed="
    .. tostring(contents.heading_concealed(A, 1))
)

-- Scenario 2: closing the only CONTENTS window tears down buffer state.
vim.api.nvim_win_close(W2, true)
vim.wait(50)
check(
  "after closing the CONTENTS window: is_active(a.org) false",
  contents.is_active(A) == false,
  "is_active(A) = " .. tostring(contents.is_active(A))
)
local za
for _, m in ipairs(vim.api.nvim_buf_get_keymap(A, "n")) do
  if m.lhs == "za" then
    za = m
  end
end
check("buffer-local za override removed", za == nil, za and ("desc: " .. tostring(za.desc)))
vim.api.nvim_set_current_win(W1)
vim.api.nvim_win_set_cursor(W1, { 1, 0 })
vim.cmd("normal za")
vim.wait(50)
check(
  "za in the remaining window closes the heading fold",
  vim.fn.foldclosed(1) == 1,
  "foldclosed(1)=" .. vim.fn.foldclosed(1)
)

-- Scenario 3: the only window showing a.org enters CONTENTS, then `:e
-- b.org` (BufWinLeave path) and comes back with `:buffer a.org`.
vim.cmd("silent! %foldopen!")
fold.apply_content(W1, A)
check("W1 in CONTENTS for a.org", contents.is_active(W1) == true)
edit_org(dir .. "/b.org")
check("W1 shows b.org", vim.api.nvim_win_get_buf(W1) == B)
check("W1 not in CONTENTS after :e b.org", contents.is_active(W1) == false)
check("W1 on b.org: conceallevel not raised", vim.wo[W1].conceallevel == 0)
vim.cmd("buffer " .. A)
vim.wait(50)
check(
  "W1 back on a.org: conceallevel not raised",
  vim.wo[W1].conceallevel == 0,
  "conceallevel=" .. vim.wo[W1].conceallevel
)
check(
  "W1 back on a.org: concealcursor not raised",
  vim.wo[W1].concealcursor == "",
  "concealcursor=" .. vim.wo[W1].concealcursor
)
check("W1 back on a.org: not in CONTENTS", contents.is_active(W1) == false)

vim.fn.delete(dir, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_stale_window_test: PASS")
os.exit(0)
