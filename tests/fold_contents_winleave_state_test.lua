-- contents.enter() records `_win_active[winid] = true` and per-winid
-- saved options in `state[bufnr].win_saved[winid]`.  The cleanup paths
-- that drop those entries are: explicit M.leave() / WinClosed.
-- Neither fires when the user does `:edit other_file` in a CONTENTS-
-- active window -- the org buffer leaves the window but the state
-- entries persist forever.  Subsequent queries (M.is_active(winid))
-- still report CONTENTS active for that winid even though the window
-- now shows a different buffer.
--
-- Contract: BufWinLeave on the org buffer (registered in the per-
-- buffer augroup at enter() time) drops the leaving winid from
-- `_win_active` and `state[bufnr].win_saved`, refcounting buffer-level
-- teardown the same way explicit leave() does.
--
-- Run via: nvim --headless -l tests/fold_contents_winleave_state_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

if not require("organ.fold.contents").is_supported() then
  print("(skipped: nvim does not support `conceal_lines` extmark)")
  print("fold_contents_winleave_state_test: SKIP")
  os.exit(0)
end

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  fold = { auto_statuscolumn = false, body_fold = false },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

vim.cmd("edit /tmp/state_a.org")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "* H", "body" })
vim.bo.filetype = "org"
vim.cmd("doautocmd FileType org")

-- Enter CONTENTS via cycle_global (S-Tab equivalent).
local fold = require("organ.fold")
fold.cycle_global(0) -- SHOW_ALL -> OVERVIEW
fold.cycle_global(0) -- OVERVIEW -> CONTENTS

local contents = require("organ.fold.contents")
local winid = vim.api.nvim_get_current_win()

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

check(
  "winid is in CONTENTS state after cycle_global x2",
  contents.is_active(winid) == true,
  "is_active returned " .. tostring(contents.is_active(winid))
)

-- Switch to a non-org buffer in the same window.  This is the user's
-- "open lua file in same window" flow.
vim.cmd("edit /tmp/state_b.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "function f() end" })
vim.bo.filetype = "lua"

-- The org buffer left the window, so the contents module must NO
-- LONGER consider this winid in CONTENTS state.
check(
  "winid is NOT in CONTENTS state after :edit other_file",
  contents.is_active(winid) ~= true,
  "is_active still returned "
    .. tostring(contents.is_active(winid))
    .. " -- BufWinLeave didn't drop it"
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_winleave_state_test: PASS")
os.exit(0)
