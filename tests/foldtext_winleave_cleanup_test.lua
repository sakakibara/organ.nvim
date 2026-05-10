-- ftplugin's apply_fold_window_opts sets win-local 'foldtext',
-- 'statuscolumn', 'fillchars', 'winhighlight', 'conceallevel',
-- 'concealcursor' on the org buffer's window.  Some of those persist
-- across buffer changes in some flows / nvim versions; the lua buffer
-- that next inhabits the window then renders folds through
-- `_organ_foldtext`'s non-org fallback (which returns
-- `vim.fn.foldtext()` -- a plain string in nvim 0.12 -- losing
-- per-token syntax highlights), with `fillchars[fold:]` swallowed to
-- space and the `Folded` highlight remapped to OrgFolded (bg=NONE).
--
-- Contract: BufWinLeave on the org buffer reverts those win-local
-- overrides via `setlocal opt<` so the next buffer in this window
-- inherits its own / the global value cleanly.
--
-- Run via: nvim --headless -l tests/foldtext_winleave_cleanup_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  fold = { auto_foldtext = true, auto_statuscolumn = true },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

-- Open an org buffer and let the ftplugin install its overrides.
vim.cmd("edit /tmp/winleave.org")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "* H", "body" })
vim.bo.filetype = "org"
vim.cmd("doautocmd FileType org")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Sanity: ftplugin installed the overrides on this window.
check(
  "win foldtext is _organ_foldtext (ftplugin applied)",
  vim.api.nvim_get_option_value("foldtext", { win = 0 }):find("_organ_foldtext", 1, true) ~= nil
)
check(
  "win winhighlight contains Folded:OrgFolded",
  vim.api.nvim_get_option_value("winhighlight", { win = 0 }):find("Folded:OrgFolded", 1, true)
    ~= nil
)
check(
  "win fillchars contains fold: (space)",
  vim.api.nvim_get_option_value("fillchars", { win = 0 }):find("fold: ", 1, true) ~= nil
)

-- Switch to a non-org buffer in the same window via :edit.
vim.cmd("edit /tmp/winleave.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "function f() end" })
vim.bo.filetype = "lua"

-- After BufWinLeave (which fired during :edit), our win-local overrides
-- must be gone.  setlocal opt< reverts to the global value, so:
--   foldtext should NOT contain "_organ_foldtext"
--   winhighlight should NOT contain "Folded:OrgFolded"
--   fillchars should NOT contain "fold: "
check(
  "lua window: foldtext no longer references _organ_foldtext",
  vim.api.nvim_get_option_value("foldtext", { win = 0 }):find("_organ_foldtext", 1, true) == nil,
  ("got %q"):format(vim.api.nvim_get_option_value("foldtext", { win = 0 }))
)
check(
  "lua window: winhighlight no longer remaps Folded to OrgFolded",
  vim.api.nvim_get_option_value("winhighlight", { win = 0 }):find("Folded:OrgFolded", 1, true)
    == nil,
  ("got %q"):format(vim.api.nvim_get_option_value("winhighlight", { win = 0 }))
)
check(
  "lua window: fillchars no longer overrides fold: to space",
  vim.api.nvim_get_option_value("fillchars", { win = 0 }):find("fold: ", 1, true) == nil,
  ("got %q"):format(vim.api.nvim_get_option_value("fillchars", { win = 0 }))
)

-- Re-entering the org buffer should re-apply the overrides (BufWinEnter
-- autocmd fires apply_fold_window_opts).
vim.cmd("edit /tmp/winleave.org")
check(
  "re-entering org window: foldtext is _organ_foldtext again",
  vim.api.nvim_get_option_value("foldtext", { win = 0 }):find("_organ_foldtext", 1, true) ~= nil,
  ("got %q"):format(vim.api.nvim_get_option_value("foldtext", { win = 0 }))
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("foldtext_winleave_cleanup_test: PASS")
os.exit(0)
