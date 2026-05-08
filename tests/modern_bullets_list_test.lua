-- modern.bullets: list-item bullet decoration + checkbox glyph (parity
-- with org-bullets.nvim's `symbols.list` / `symbols.checkboxes`).
-- Run via: nvim --headless -l tests/modern_bullets_list_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  modern = { bullets = true },
})

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Heading",
  "- plain item",
  "+ alt-marker item",
  "- [ ] todo box",
  "- [X] done box (uppercase)",
  "- [x] done box (lowercase)",
  "- [-] half box",
  "1. numbered with [ ] checkbox",
  "Body text [ ] not in a list — should NOT decorate",
  "  - indented item",
})
vim.bo[bufnr].filetype = "org"
vim.api.nvim_set_current_buf(bufnr)

require("organ.modern.bullets").attach(bufnr)

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local NS = vim.api.nvim_get_namespaces()["organ_modern_bullets"]
local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })

-- Bucket marks by row.
local by_row = {}
for _, m in ipairs(marks) do
  by_row[m[2]] = by_row[m[2]] or {}
  table.insert(by_row[m[2]], m)
end

local function row_conceals(row)
  local out = {}
  for _, m in ipairs(by_row[row] or {}) do
    table.insert(out, (m[4] or {}).conceal)
  end
  return out
end

local function row_has_conceal(row, ch)
  for _, m in ipairs(by_row[row] or {}) do
    if (m[4] or {}).conceal == ch then
      return true
    end
  end
  return false
end

local function row_has_conceal_at(row, col, ch)
  for _, m in ipairs(by_row[row] or {}) do
    local d = m[4] or {}
    if d.conceal == ch and m[3] == col and d.end_col == col + 1 then
      return true
    end
  end
  return false
end

check("row 0 (heading): bullet glyph (◉)", row_has_conceal(0, "◉"))

check("row 1 (- plain): list bullet (•) at col 0", row_has_conceal_at(1, 0, "•"))
check("row 2 (+ alt):  list bullet (•) at col 0", row_has_conceal_at(2, 0, "•"))

check("row 3 (- [ ]): TODO checkbox (˟)", row_has_conceal(3, "˟"))
check("row 4 (- [X]): DONE checkbox (✓)", row_has_conceal(4, "✓"))
check("row 5 (- [x]): DONE checkbox (✓) — lowercase too", row_has_conceal(5, "✓"))
check("row 6 (- [-]): HALF checkbox (▣)", row_has_conceal(6, "▣"))

check("row 7 (1. numbered with [ ]): TODO checkbox concealed", row_has_conceal(7, "˟"))

-- The plain "Body text" line with [ ] should NOT have a checkbox conceal.
local row8 = row_conceals(8)
local has_box_glyph = false
for _, c in ipairs(row8) do
  if c == "˟" or c == "✓" or c == "▣" then
    has_box_glyph = true
  end
end
check(
  "row 8 (body text [ ]): NO checkbox decoration on non-list line",
  not has_box_glyph,
  "got conceals: " .. vim.inspect(row8)
)

check("row 9 (  - indented): list bullet (•) at col 2", row_has_conceal_at(9, 2, "•"))

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_bullets_list_test: PASS")
