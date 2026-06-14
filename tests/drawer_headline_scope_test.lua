-- The drawer regex fallback (used when no tree-sitter parser is loaded)
-- must not scan past the next headline. An unterminated drawer under one
-- headline previously swallowed the following sibling's content, and an
-- unterminated property drawer pushed the insert position past EOF.
-- Run via: nvim --headless -l tests/drawer_headline_scope_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local drawer = require("organ.drawer")

-- The org parser attaches to any buffer by language, so the regex fallback
-- only runs when the parser is genuinely unavailable. Force that path.
local element = require("organ.element")
element.parser_loaded = function()
  return false
end

local function check(cond, label)
  if cond then
    print("PASS  " .. label)
  else
    print("FAIL  " .. label)
    os.exit(1)
  end
end

-- Headline A's LOGBOOK is never closed; headline B that follows has its own.
local lines = {
  "* TODO A", -- 1
  ":LOGBOOK:", -- 2  (unterminated under A)
  "CLOCK: [2026-01-01 Thu 09:00]", -- 3
  "* TODO B", -- 4
  ":LOGBOOK:", -- 5
  "- note", -- 6
  ":END:", -- 7
}

local s = drawer.find(lines, 1, "LOGBOOK", 0)
check(s == nil, "unterminated drawer under A is not reported (no scan past the next headline)")

local s2, e2 = drawer.find(lines, 4, "LOGBOOK", 0)
check(s2 == 5 and e2 == 7, "well-formed drawer under B resolves to its own range")

-- An unterminated PROPERTIES drawer under A: the insert position must land
-- within A's section (at B's headline), never past the whole buffer.
local plines = {
  "* TODO A", -- 1
  ":PROPERTIES:", -- 2  (unterminated)
  ":ID: a1", -- 3
  "* TODO B", -- 4
  "body", -- 5
}
local pos = drawer.insert_position(plines, 1, 0)
check(pos == 4, "insert position under A stops at B's headline, not past EOF")

-- Well-formed property drawer still yields the line after :END:.
local wlines = {
  "* TODO A", -- 1
  ":PROPERTIES:", -- 2
  ":ID: a1", -- 3
  ":END:", -- 4
  "body", -- 5
}
check(drawer.insert_position(wlines, 1, 0) == 5, "well-formed property drawer: insert after :END:")

print("drawer_headline_scope_test: PASS")
