-- Persistent roam sidebar (`:Org roam buffer`).  Lifecycle invariants:
--
--   * <CR> / gs / gv inside the sidebar jump in the user's main
--     editing window, leaving the sidebar window intact.
--   * Closing the sidebar window by any means (`:close`, `<C-w>q`,
--     M.close()) tears down state + the autocmd group.
--   * Toggle / pin / re-open are idempotent.
--
-- Run via: nvim --headless -l tests/roam_sidebar_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")

-- Two notes that link to each other so backlinks have something to render.
-- Headline-level IDs (indexer only catches IDs on headlines, not on
-- the file-level zeroth-section drawer).
local f1 = org_dir .. "/note1.org"
do
  local f = assert(io.open(f1, "w"))
  f:write([==[
* Note 1
  :PROPERTIES:
  :ID:       note1-id
  :END:

A reference to [[id:note2-id][Note 2]].
]==])
  f:close()
end
local f2 = org_dir .. "/note2.org"
do
  local f = assert(io.open(f2, "w"))
  f:write([==[
* Note 2
  :PROPERTIES:
  :ID:       note2-id
  :END:

Linked back from [[id:note1-id][Note 1]].
]==])
  f:close()
end

require("organ").setup({
  db_path = tmp .. "/sidebar.db",
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})
require("organ").scan_blocking(org_dir, 5000)

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local sidebar = require("organ.roam.sidebar")

-- Open note2 in the current (only) window.  This is the user's
-- editing window; the sidebar should remember it as the jump target.
vim.cmd("edit " .. vim.fn.fnameescape(f2))
-- Force ft = "org" — `nvim --headless -l` skips the FileType autocmd
-- chain that would otherwise be triggered by `vim.filetype.add` in
-- plugin/organ.lua, leaving `vim.bo.filetype` empty.
vim.bo.filetype = "org"
local origin_win = vim.api.nvim_get_current_win()

-- ---------------------------------------------------------------------------
-- (a) Open: sidebar window appears; state populated; origin_win
--     recorded as target.
-- ---------------------------------------------------------------------------
sidebar.open()

check("open: state.winid set", sidebar._state().winid ~= nil)
check("open: state.bufnr set", sidebar._state().bufnr ~= nil)
check(
  "open: target_winid points at the user's editing window",
  sidebar._state().target_winid == origin_win,
  ("got %s, want %s"):format(tostring(sidebar._state().target_winid), tostring(origin_win))
)

local sidebar_win = sidebar._state().winid
local sidebar_buf = sidebar._state().bufnr

-- ---------------------------------------------------------------------------
-- (b) The sidebar buffer is distinct from the user's editing buffer.
-- ---------------------------------------------------------------------------
check(
  "sidebar window holds the sidebar buffer",
  vim.api.nvim_win_get_buf(sidebar_win) == sidebar_buf
)
check(
  "user's editing window still holds note2.org",
  vim.api.nvim_win_get_buf(origin_win) == vim.fn.bufnr(f2)
)

-- ---------------------------------------------------------------------------
-- (c) <CR> jump must NOT replace the sidebar buffer; it should land in
--     the target window.  Find a row in the rendered text that points
--     at note1 (which links to note2) and trigger <CR> on it.
-- ---------------------------------------------------------------------------
local body = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false)
local target_lnum
-- Backlink entries render on two lines (title + location).  The
-- location line carries the `note1.org` basename; jumping from
-- either lands on the same source row.
for i, line in ipairs(body) do
  if line:find("note1.org", 1, true) then
    target_lnum = i
    break
  end
end
if target_lnum == nil then
  print("DEBUG sidebar body: " .. vim.inspect(body))
end
check("rendered a backlink row pointing at note1.org", target_lnum ~= nil)

if target_lnum then
  vim.api.nvim_set_current_win(sidebar_win)
  vim.api.nvim_win_set_cursor(sidebar_win, { target_lnum, 0 })
  -- Fire the buffer-local <CR> mapping by invoking its callback.
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(sidebar_buf, "n")) do
    if m.lhs == "<CR>" and m.callback then
      m.callback()
      break
    end
  end
  check(
    "after jump: sidebar window still holds the sidebar buffer",
    vim.api.nvim_win_is_valid(sidebar_win) and vim.api.nvim_win_get_buf(sidebar_win) == sidebar_buf
  )
  check(
    "after jump: target window now holds note1.org",
    vim.api.nvim_win_is_valid(origin_win)
      and vim.fn.fnamemodify(
          vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin_win)),
          ":t"
        )
        == "note1.org"
  )
end

-- ---------------------------------------------------------------------------
-- (d) Manual window close → state torn down.
-- ---------------------------------------------------------------------------
vim.api.nvim_win_close(sidebar_win, true)
-- WinClosed is scheduled; flush.
vim.cmd("doautocmd WinClosed " .. tostring(sidebar_win))
vim.wait(50, function()
  return sidebar._state().winid == nil
end)
check(
  "manual :close: state.winid cleared by WinClosed cleanup",
  sidebar._state().winid == nil,
  "state still has winid=" .. tostring(sidebar._state().winid)
)
check("manual :close: state.bufnr cleared", sidebar._state().bufnr == nil)

-- ---------------------------------------------------------------------------
-- (e) toggle: open then close idempotently.
-- ---------------------------------------------------------------------------
sidebar.toggle()
check("toggle from closed → open", sidebar._state().winid ~= nil)
sidebar.toggle()
check("toggle from open → closed", sidebar._state().winid == nil)

-- ---------------------------------------------------------------------------
-- (f) close() called twice is a no-op (no error).
-- ---------------------------------------------------------------------------
local ok = pcall(sidebar.close)
check("close() on already-closed sidebar is a no-op", ok)

-- ---------------------------------------------------------------------------
-- (g) Tab-local: opening in tab 1 leaves tab 2 alone.  Each tab has
--     its own bufnr / winid; close on tab 1 doesn't affect tab 2.
-- ---------------------------------------------------------------------------
do
  vim.cmd("tabnew " .. vim.fn.fnameescape(f2))
  vim.bo.filetype = "org"
  local tab2 = vim.api.nvim_get_current_tabpage()

  sidebar.open()
  local s2_win = sidebar._state(tab2).winid
  check("tab 2: open created its own sidebar window", s2_win ~= nil)

  -- Switch to tab 1.
  vim.cmd("tabprevious")
  local tab1 = vim.api.nvim_get_current_tabpage()
  check("tab 1: no sidebar yet (state independent of tab 2)", sidebar._state(tab1).winid == nil)

  -- Open on tab 1.
  vim.cmd("edit " .. vim.fn.fnameescape(f2))
  vim.bo.filetype = "org"
  sidebar.open()
  local s1_win = sidebar._state(tab1).winid
  check("tab 1: own sidebar window created", s1_win ~= nil)
  check("tab 1 and tab 2 have distinct sidebar winids", s1_win ~= s2_win)

  -- Close on tab 1; tab 2's sidebar must still exist.
  sidebar.close()
  check("tab 1: close cleared its own state", sidebar._state(tab1).winid == nil)
  check(
    "tab 2: sidebar still open after tab 1 close",
    sidebar._state(tab2).winid == s2_win and vim.api.nvim_win_is_valid(sidebar._state(tab2).winid)
  )

  -- Cleanup tab 2.
  vim.cmd("tabnext")
  sidebar.close()
  vim.cmd("tabclose")
end

-- ---------------------------------------------------------------------------
-- (h) Resize persistence: a user-driven resize is remembered across
--     close + reopen on the same tab.
-- ---------------------------------------------------------------------------
do
  vim.cmd("edit " .. vim.fn.fnameescape(f2))
  vim.bo.filetype = "org"
  sidebar.open()
  local s = sidebar._state()
  -- Simulate the user resizing via `:vertical resize 80`.
  -- Headless nvim defaults to 80 columns; pick 30 so the resize
  -- isn't clamped against the main window's minimum width.
  pcall(vim.api.nvim_win_set_width, s.winid, 30)
  -- Trigger WinResized so our autocmd records last_width.
  vim.cmd("doautocmd WinResized")
  vim.wait(20)
  check(
    "resize persisted in state.last_width",
    s.last_width == 30,
    "got " .. tostring(s.last_width)
  )

  sidebar.close()
  -- Reopen — the new sidebar should pick up the persisted width.
  sidebar.open()
  local reopened = sidebar._state()
  check(
    "reopen restored 30-column width",
    vim.api.nvim_win_get_width(reopened.winid) == 30,
    "got " .. tostring(vim.api.nvim_win_get_width(reopened.winid))
  )
  sidebar.close()
end

vim.fn.delete(tmp, "rf")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("roam_sidebar_test: PASS")
