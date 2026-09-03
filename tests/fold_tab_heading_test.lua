-- A headline is `*+` followed by a SPACE (Emacs `org-outline-regexp`
-- "\\*+ "; the grammar agrees).  `*<TAB>text` is body text: it must not
-- start a fold, must be concealed as body in CONTENTS, and must not
-- pick up a heading highlight in foldtext.
--
-- Run via: nvim --headless -l tests/fold_tab_heading_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local fold = require("organ.fold")
local contents = require("organ.fold.contents")

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "* A", "body", "*\tnot heading", "more" })
vim.bo[bufnr].filetype = "org"
vim.api.nvim_set_current_buf(bufnr)

local levels = fold._build_fold_levels(bufnr)
check(
  "foldexpr: `*<TAB>` line stays inside the previous section",
  vim.deep_equal(levels, { ">1", "1", "1", "1" }),
  vim.inspect(levels)
)

check("heading_title_hl: `*<TAB>` is not a heading", fold.heading_title_hl("*\tfoo") == "Folded")

local winid = vim.api.nvim_get_current_win()
contents.enter(winid)
local ns = vim.api.nvim_create_namespace("organ_fold_contents")
local body_mark
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
  if m[4].conceal_lines == "" then
    body_mark = m
  end
end
check(
  "CONTENTS: one body range covering lines 2-4",
  body_mark ~= nil and body_mark[2] == 1 and body_mark[4].end_row == 3,
  body_mark and vim.inspect({ body_mark[2], body_mark[4].end_row }) or "no conceal_lines mark"
)
contents.leave(winid)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_tab_heading_test: PASS")
os.exit(0)
