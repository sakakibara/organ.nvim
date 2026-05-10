-- ftplugin's auto_foldtext / auto_statuscolumn writes win-local
-- option values, but `nvim_set_option_value(name, val, { win = 0 })`
-- without `scope = "local"` is equivalent to `:set` -- it clobbers the
-- GLOBAL value too.  When the user opens a non-org buffer in the same
-- window afterwards, `_organ_foldtext`'s non-org fallback reads
-- `vim.go.foldtext`, sees its own wrapper string, hits the recursion
-- guard, and falls to vim's default `+--  N lines:` rendering -- the
-- user's customised global foldtext is gone.
--
-- Contract: ftplugin sets only win-local; user's global stays intact;
-- _organ_foldtext on non-org delegates to the (preserved) global.
--
-- Run via: nvim --headless -l tests/foldtext_global_preserved_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- User pre-configures a custom global foldtext BEFORE organ loads.
_G.MyFoldtext = function()
  return "USER_CUSTOM_FOLDTEXT"
end
vim.opt.foldtext = "v:lua.MyFoldtext()"

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  fold = { auto_foldtext = true, auto_statuscolumn = true },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local b_org = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b_org)
vim.api.nvim_buf_set_lines(b_org, 0, -1, false, { "* H1", "  body" })
vim.bo[b_org].filetype = "org"
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

-- After ftplugin runs, the GLOBAL foldtext must still be the user's
-- custom setting -- ftplugin should set only win-local.
check(
  "global foldtext preserved after ftplugin",
  vim.go.foldtext == "v:lua.MyFoldtext()",
  ("expected %q, got %q"):format("v:lua.MyFoldtext()", vim.go.foldtext)
)

-- Win-local IS our wrapper (correct: drives organ.fold.foldtext on org).
check(
  "win-local foldtext is _organ_foldtext",
  vim.api.nvim_get_option_value("foldtext", { win = 0 }):find("_organ_foldtext", 1, true) ~= nil,
  ("got %q"):format(vim.api.nvim_get_option_value("foldtext", { win = 0 }))
)

-- Now switch this window's buffer to a lua file.  Win-local foldtext
-- stays as our wrapper (window options persist across buffer changes).
local b_lua = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b_lua)
vim.api.nvim_buf_set_lines(b_lua, 0, -1, false, { "function f() end" })
vim.bo[b_lua].filetype = "lua"

-- _organ_foldtext on the lua buffer must delegate to the user's
-- custom global, not vim's default.
vim.v.foldstart = 1
vim.v.foldend = 1
local out = _G._organ_foldtext()
check(
  "_organ_foldtext on lua buffer delegates to user's global foldtext",
  out == "USER_CUSTOM_FOLDTEXT",
  ("expected USER_CUSTOM_FOLDTEXT, got %q"):format(tostring(out))
)

-- Same contract for statuscolumn (the user might have a custom global
-- statuscolumn for non-org filetypes).
check(
  "global statuscolumn NOT clobbered by ftplugin",
  not vim.go.statuscolumn:find("_organ_statuscolumn", 1, true),
  ("got %q"):format(vim.go.statuscolumn)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("foldtext_global_preserved_test: PASS")
os.exit(0)
