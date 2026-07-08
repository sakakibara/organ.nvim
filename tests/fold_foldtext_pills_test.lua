-- A closed fold renders foldtext, not the real line, so the pill extmarks
-- never reach it. emacs_foldtext must redraw the TODO keyword as its modern
-- pill (reversed body + inline caps) so a folded heading matches an expanded
-- one -- otherwise a folded `* TODO Foo` shows a plain keyword, not the pill.
--
-- Run via: nvim --headless -l tests/fold_foldtext_pills_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xf38ba8 })
require("organ").setup({ todo = { sequence = { "TODO", "|", "DONE" } } })

local fold = require("organ.fold")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function foldtext_of(lines, pills_on)
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  require("organ.buf_config").set(b, "modern.pills", pills_on)
  pcall(vim.treesitter.start, b, "org")
  vim.cmd("let v:foldstart = 1")
  vim.cmd("let v:foldend = " .. #lines)
  return fold.foldtext()
end

local function has_hl(segs, hl)
  for _, s in ipairs(segs) do
    if s[2] == hl then
      return true
    end
  end
  return false
end
local function keyword_seg(segs, text)
  for _, s in ipairs(segs) do
    if s[1] == text then
      return s
    end
  end
end

-- pills on: the TODO keyword segment carries the reversed pill body group,
-- flanked by cap segments.
do
  local t = foldtext_of({ "* TODO Buy milk", "  body" }, true)
  local kw = keyword_seg(t, "TODO")
  check("TODO keyword uses the reversed pill body group",
    kw ~= nil and kw[2] == "@organ.modern.badge.pill.todo", kw and vim.inspect(kw) or "no TODO seg")
  check("pill caps are drawn around the keyword",
    has_hl(t, "@organ.modern.badgecap.pill.todo"), vim.inspect(t))
end

-- DONE keyword too (a done-bucket pill).
do
  local t = foldtext_of({ "* DONE Ship it", "  body" }, true)
  local kw = keyword_seg(t, "DONE")
  check("DONE keyword uses its pill body group",
    kw ~= nil and kw[2] == "@organ.modern.badge.pill.done", kw and vim.inspect(kw) or "no DONE seg")
end

-- pills off: the keyword keeps its plain treesitter highlight, no pill group.
do
  local t = foldtext_of({ "* TODO Buy milk", "  body" }, false)
  check("pills off leaves the keyword un-pilled",
    not has_hl(t, "@organ.modern.badge.pill.todo"), vim.inspect(t))
  local kw = keyword_seg(t, "TODO")
  check("pills off keeps the todo highlight", kw ~= nil and kw[2]:match("^@org%.todo") ~= nil,
    kw and vim.inspect(kw) or "no TODO seg")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_foldtext_pills_test: PASS")
os.exit(0)
