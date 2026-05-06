-- Unit tests for organ.drawer — find LOGBOOK / drawer + insert position.
-- Run via: nvim --headless -l tests/drawer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local drawer = require("organ.drawer")

-- 1. Find existing LOGBOOK drawer.
do
  local lines = {
    "* Heading",
    "  :PROPERTIES:",
    "  :ID: abc",
    "  :END:",
    "  :LOGBOOK:",
    '  - State "DONE" from "TODO" [2026-04-26 Sun 14:00] \\\\',
    "  :END:",
    "  body line",
  }
  local s, e = drawer.find(lines, 1, "LOGBOOK")
  assert(s == 5, "expected start 5; got " .. tostring(s))
  assert(e == 7, "expected end 7; got " .. tostring(e))
end

-- 2. Find LOGBOOK absent → returns nil, nil.
do
  local lines = {
    "* Heading",
    "  :PROPERTIES:",
    "  :ID: abc",
    "  :END:",
    "  body line",
  }
  local s, e = drawer.find(lines, 1, "LOGBOOK")
  assert(s == nil and e == nil, "expected nils; got " .. tostring(s) .. "," .. tostring(e))
end

-- 3. insert_position with no planning + no property drawer → right after headline.
do
  local lines = { "* Heading", "  body line" }
  local p = drawer.insert_position(lines, 1)
  assert(p == 2, "expected 2; got " .. tostring(p))
end

-- 4. insert_position with property drawer → after :END: of properties.
do
  local lines = {
    "* Heading",
    "  :PROPERTIES:",
    "  :ID: abc",
    "  :END:",
    "  body line",
  }
  local p = drawer.insert_position(lines, 1)
  assert(p == 5, "expected 5; got " .. tostring(p))
end

-- 5. insert_position with planning + properties → after both.
do
  local lines = {
    "* Heading",
    "  SCHEDULED: <2026-04-26 Sun>",
    "  :PROPERTIES:",
    "  :ID: abc",
    "  :END:",
    "  body line",
  }
  local p = drawer.insert_position(lines, 1)
  assert(p == 6, "expected 6; got " .. tostring(p))
end

-- 6. find honours arbitrary drawer names (not just LOGBOOK).
do
  local lines = {
    "* Heading",
    "  :CUSTOM:",
    "  payload",
    "  :END:",
  }
  local s, e = drawer.find(lines, 1, "CUSTOM")
  assert(s == 2 and e == 4, "got " .. tostring(s) .. "," .. tostring(e))
end

io.write("drawer ok\n")
os.exit(0)
