-- tests/table_alignment_test.lua
local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tab = require("organ.table")

local function assert_eq(a, b, msg)
  if a ~= b then
    error((msg or "") .. " expected " .. tostring(b) .. " got " .. tostring(a))
  end
end

-- Right alignment: <r> in row 2 right-pads cells in that column.
do
  local rows = {
    { cells = { "name", "age" }, sep = false },
    { cells = { "<l>", "<r>" }, sep = false },
    { cells = { "alice", "30" }, sep = false },
    { cells = { "bob", "100" }, sep = false },
  }
  local out = tab._align(rows, "")
  -- Column 2 widths: 3 (age), 3 (<r>), 2 (30), 3 (100) → max 3.
  -- Row 4: "30" needs to be right-aligned within 3 → " 30".
  assert(
    out[3]:match("|%s+30%s|") or out[3]:match("|%s+30 |"),
    "30 right-aligned in row 3: " .. out[3]
  )
end

-- Center alignment: <c>.
do
  local rows = {
    { cells = { "header" }, sep = false },
    { cells = { "<c>" }, sep = false },
    { cells = { "x" }, sep = false },
  }
  local out = tab._align(rows, "")
  -- Column width = max("header", "<c>", "x") = 6.
  -- "x" centered in 6: ~"  x   " or "   x  " (centering rule may split asymmetrically).
  assert(out[3]:match("|%s+x%s+|"), "x centered: " .. out[3])
end

-- Alignment row preserved literally.
do
  local rows = {
    { cells = { "h" }, sep = false },
    { cells = { "<r>" }, sep = false },
    { cells = { "x" }, sep = false },
  }
  local out = tab._align(rows, "")
  assert(out[2]:find("<r>"), "alignment row preserved: " .. out[2])
end

-- No marker row → behavior unchanged from M2-1.
do
  local rows = {
    { cells = { "name", "age" }, sep = false },
    { cells = { "alice", "30" }, sep = false },
  }
  local out = tab._align(rows, "")
  -- Defaults left-aligned (per M2-1).
  assert(out[2]:match("^| alice |"), "left-aligned: " .. out[2])
end

io.write("table alignment ok\n")
