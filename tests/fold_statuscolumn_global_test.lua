-- The auto_statuscolumn / auto_foldtext options point at flat globals
-- (`_organ_statuscolumn`, `_organ_foldtext`).  Vim evaluates those
-- strings at redraw time -- if a CursorMoved elsewhere triggers a
-- redraw before `organ.fold` has been required (foldexpr loads it
-- lazily on first eval), the globals are nil and vim throws
--   "attempt to call global '_organ_statuscolumn' (a nil value)".
-- ftplugin must require organ.fold BEFORE setting the option strings
-- so the load order is deterministic.
--
-- Run via: nvim --headless -l tests/fold_statuscolumn_global_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  fold = { auto_statuscolumn = true, auto_foldtext = true },
})
local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

-- Open an org buffer; ftplugin runs, applies the win-local options.
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "* H1", "  body", "* H2", "  body" })
vim.api.nvim_set_current_buf(b)
vim.bo[b].filetype = "org"
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

-- The contract: by the time ftplugin returns, the globals MUST exist
-- so any subsequent redraw can evaluate the option strings safely.
check(
  "_organ_statuscolumn defined after FileType",
  type(_G._organ_statuscolumn) == "function",
  "got " .. type(_G._organ_statuscolumn)
)
check(
  "_organ_foldtext defined after FileType",
  type(_G._organ_foldtext) == "function",
  "got " .. type(_G._organ_foldtext)
)

-- Sanity: the option strings on this window match what we expect.
local sc = vim.api.nvim_get_option_value("statuscolumn", { win = 0 })
local ft = vim.api.nvim_get_option_value("foldtext", { win = 0 })
check(
  "statuscolumn references _organ_statuscolumn",
  sc:find("_organ_statuscolumn", 1, true) ~= nil,
  ("got %q"):format(sc)
)
check(
  "foldtext references _organ_foldtext",
  ft:find("_organ_foldtext", 1, true) ~= nil,
  ("got %q"):format(ft)
)

-- Belt-and-suspenders: actually invoke each global to confirm it
-- doesn't blow up when called the way vim's option eval would.
local ok_sc, sc_err = pcall(function()
  vim.api.nvim_buf_call(b, function()
    -- _organ_statuscolumn reads v:lnum, v:relnum, v:virtnum -- those
    -- are read-only but have safe defaults of 0 outside an active
    -- redraw, so the call should still complete without error.
    return _G._organ_statuscolumn()
  end)
end)
check("_organ_statuscolumn() executes without error", ok_sc, not ok_sc and tostring(sc_err) or nil)

local ok_ft, ft_err = pcall(function()
  vim.api.nvim_buf_call(b, function()
    return _G._organ_foldtext()
  end)
end)
check("_organ_foldtext() executes without error", ok_ft, not ok_ft and tostring(ft_err) or nil)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_statuscolumn_global_test: PASS")
