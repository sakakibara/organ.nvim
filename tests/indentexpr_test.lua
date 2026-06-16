-- org indentexpr: M.compute(bufnr, lnum) returns the formatter's indent.
-- Run via: nvim --headless -l tests/indentexpr_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local ix = require("organ.indentexpr")

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

local function mkbuf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  return b
end

-- headline -> 0; planning/property/logbook -> level+1; body -> -1.
do
  local b = mkbuf({
    "* TODO Task", -- 1 headline level 1
    "DEADLINE: <2026-06-17 Wed>", -- 2 planning
    ":PROPERTIES:", -- 3 drawer open
    ":ID: abc", -- 4 drawer line
    ":END:", -- 5 drawer close
    ":LOGBOOK:", -- 6 logbook open
    "CLOCK: x", -- 7 logbook line
    ":END:", -- 8 logbook close
    "body text", -- 9 body
  })
  check(ix.compute(b, 1) == 0, "headline -> 0")
  check(ix.compute(b, 2) == 2, "planning -> level+1 (2)")
  check(ix.compute(b, 3) == 2, "property open -> 2")
  check(ix.compute(b, 4) == 2, "property line -> 2")
  check(ix.compute(b, 5) == 2, "property close -> 2")
  check(ix.compute(b, 6) == 2, "logbook open -> 2")
  check(ix.compute(b, 7) == 2, "logbook line -> 2")
  check(ix.compute(b, 9) == -1, "body -> -1 (keep, adapt off)")
end

-- deeper level -> level+1.
do
  local b = mkbuf({ "* H1", "*** H3", "DEADLINE: <x>" })
  check(ix.compute(b, 2) == 0, "headline level 3 -> 0")
  check(ix.compute(b, 3) == 4, "planning under level-3 -> 4")
end

-- before any headline -> -1.
do
  local b = mkbuf({ "#+TITLE: x", "intro" })
  check(ix.compute(b, 2) == -1, "line before first headline -> -1")
end

-- body adapt on -> (level-1)*shift+1; block content stays -1.
do
  local b = mkbuf({ "* H", "body", "", "#+begin_src lua", "print(1)", "#+end_src" })
  require("organ.buf_config").set(b, "indent.adapt_indentation", true)
  check(ix.compute(b, 2) == 1, "body adapt on, level1 -> 1")
  check(ix.compute(b, 3) == -1, "blank line adapt on -> -1 (formatter leaves blanks)")
  check(ix.compute(b, 5) == -1, "block content -> -1 even with adapt on")
end

print("ALL PASS: indentexpr")
