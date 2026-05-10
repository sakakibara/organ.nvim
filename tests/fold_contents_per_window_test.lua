-- Per-window CONTENTS view: when two splits show the same org buffer
-- and the user enters CONTENTS state in window A (S-Tab cycles
-- SHOW_ALL -> OVERVIEW -> CONTENTS), window B's body lines must remain
-- visible.  CONTENTS state is a per-window concern: the focused
-- window's cycle action should not affect peer windows showing the
-- same file.
--
-- Mechanism (verified separately): a decoration provider on `on_win`
-- swaps body conceal_lines extmarks per rendering window so vim's
-- layout sees CONTENTS state for windows that asked for it and
-- SHOW_ALL state for everyone else.  All within the same redraw
-- cycle.
--
-- Run via: nvim --headless -l tests/fold_contents_per_window_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

if not require("organ.fold.contents").is_supported() then
  print("(skipped: nvim does not support `conceal_lines` extmark)")
  print("fold_contents_per_window_test: SKIP")
  os.exit(0)
end

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  fold = { auto_statuscolumn = false, body_fold = false },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

-- The decoration provider needs a real screen to draw against.  Force
-- a wide screen so vsplit columns are large enough to display labels.
vim.o.lines = 14
vim.o.columns = 80

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1",
  "  body of H1 line 1",
  "  body of H1 line 2",
  "* H2",
  "  body of H2",
})
vim.bo[b].filetype = "org"
vim.cmd("doautocmd FileType org")

vim.cmd("vsplit")
local wins = vim.api.nvim_list_wins()
local wA, wB = wins[2], wins[1]
vim.api.nvim_win_set_buf(wA, b)
vim.api.nvim_win_set_buf(wB, b)
for _, w in ipairs({ wA, wB }) do
  vim.api.nvim_set_current_win(w)
  vim.cmd("doautocmd FileType org")
end

-- Window A: enter CONTENTS via cycle_global (S-Tab equivalent).
-- cycle_global is the public API S-Tab calls.  In default config
-- (body_fold = false) the third state is CONTENTS via conceal_lines.
local fold = require("organ.fold")
vim.api.nvim_set_current_win(wA)
fold.cycle_global(b) -- SHOW_ALL -> OVERVIEW
fold.cycle_global(b) -- OVERVIEW -> CONTENTS
-- Window B: stay in SHOW_ALL.
vim.api.nvim_set_current_win(wB)

local contents = require("organ.fold.contents")
local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

check(
  "wA is in CONTENTS state",
  contents.is_active(wA) == true,
  "is_active(wA) returned " .. tostring(contents.is_active(wA))
)
check(
  "wB is NOT in CONTENTS state",
  contents.is_active(wB) ~= true,
  "is_active(wB) returned " .. tostring(contents.is_active(wB))
)

-- Drive a real redraw and read each window's rendered screen content.
-- conceal_lines extmarks make a body line render as "no row at all",
-- so wA's first column should have only headings while wB shows every
-- buffer line.
vim.cmd("redraw!")

local function row_text(row)
  local pieces = {}
  for col = 1, vim.o.columns do
    local s = vim.fn.screenstring(row, col)
    pieces[#pieces + 1] = s == "" and " " or s
  end
  return table.concat(pieces, ""):gsub("%s+$", "")
end

-- vsplit puts the new window on the LEFT (cols 1..~40), original on
-- the RIGHT (cols ~42..80).  Layout: wins[1] = left, wins[2] = right.
-- So wB (wins[1]) renders on the left half, wA (wins[2]) on the right.
local function left_text(row)
  local pieces = {}
  for col = 1, 40 do
    local s = vim.fn.screenstring(row, col)
    pieces[#pieces + 1] = s == "" and " " or s
  end
  return table.concat(pieces, ""):gsub("%s+$", "")
end
local function right_text(row)
  local pieces = {}
  for col = 41, vim.o.columns do
    local s = vim.fn.screenstring(row, col)
    pieces[#pieces + 1] = s == "" and " " or s
  end
  return (table.concat(pieces, ""):gsub("^[%s│]+", "")):gsub("%s+$", "")
end

print()
print("Rendered (left = wB SHOW_ALL, right = wA CONTENTS):")
for row = 1, 6 do
  print(string.format("  row %d: left=%-30s right=%s", row, left_text(row), right_text(row)))
end

-- wB (left, SHOW_ALL): row 2 should show "body of H1 line 1".
check(
  "wB row 2 shows body line (SHOW_ALL preserved)",
  left_text(2):find("body of H1 line 1", 1, true) ~= nil,
  "row 2 left = " .. left_text(2)
)
-- wA (right, CONTENTS): row 2 should NOT be a body line; it should be
-- the next heading (H2) since H1's body lines are concealed.
check(
  "wA row 2 shows next heading (body concealed)",
  right_text(2):find("H2", 1, true) ~= nil and right_text(2):find("body of H1", 1, true) == nil,
  "row 2 right = " .. right_text(2)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_per_window_test: PASS")
os.exit(0)
