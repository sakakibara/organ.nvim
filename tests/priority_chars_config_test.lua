-- Configurable priority chars (Emacs org-priority-{highest, lowest,
-- default}). Default A..C/B; can override to e.g. A..E or 1..9.
-- Run via: nvim --headless -l tests/priority_chars_config_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local ie = require("organ.inline_edit")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- ---- Default A..C/B ----
local hi, lo, def = ie._priority_range()
check("defaults: highest=A, lowest=C, default=B", hi == "A" and lo == "C" and def == "B")

check("step nil up = A", ie._step_priority(nil, 1) == "A")
check("step nil down = C", ie._step_priority(nil, -1) == "C")
check("step C up = B", ie._step_priority("C", 1) == "B")
check("step B up = A", ie._step_priority("B", 1) == "A")
check("step A up stays A (clamped)", ie._step_priority("A", 1) == "A")
check("step A down = B", ie._step_priority("A", -1) == "B")
check("step C down = nil (cleared)", ie._step_priority("C", -1) == nil)

-- ---- Override to A..E (5-level) ----
require("organ").config.priority = { highest = "A", lowest = "E", default = "C" }
hi, lo, def = ie._priority_range()
check("override A..E: highest=A, lowest=E, default=C", hi == "A" and lo == "E" and def == "C")
check("A..E: step E up = D", ie._step_priority("E", 1) == "D")
check("A..E: step C up = B", ie._step_priority("C", 1) == "B")
check("A..E: step E down = nil (cleared)", ie._step_priority("E", -1) == nil)

-- ---- Reverse alphabetical: lowest='Z', highest='A' (range A..Z) ----
require("organ").config.priority = { highest = "A", lowest = "Z", default = "M" }
check("A..Z: step M up = L", ie._step_priority("M", 1) == "L")
check("A..Z: step A up stays A", ie._step_priority("A", 1) == "A")

-- ---- Inverted: highest letter is later (e.g. 1..5 with highest=5) ----
require("organ").config.priority = { highest = "5", lowest = "1", default = "3" }
check("1..5: step 1 up = 2", ie._step_priority("1", 1) == "2")
check("1..5: step 5 up stays 5 (clamped)", ie._step_priority("5", 1) == "5")
check("1..5: step 3 down = 2", ie._step_priority("3", -1) == "2")
check("1..5: step 1 down = nil (cleared)", ie._step_priority("1", -1) == nil)
check("1..5: step nil up = 5 (highest)", ie._step_priority(nil, 1) == "5")
check("1..5: step nil down = 1 (lowest)", ie._step_priority(nil, -1) == "1")

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("priority_chars_config_test: PASS")
