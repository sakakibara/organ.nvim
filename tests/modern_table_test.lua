-- modern.table: pipe / dash / plus replaced with box-drawing chars;
-- alignment-row markers (<l>/<r>/<c>) collapsed to arrows; optional
-- virt_lines top/bottom borders.
--
-- Run via: nvim --headless -l tests/modern_table_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
  modern = { table = { border_virtual = true } },
})

local pt = require("organ.modern.table")
local NS = vim.api.nvim_create_namespace("organ_modern_table")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function with_buf(lines, fn)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].filetype = "org"
  pt.refresh(b)
  fn(b)
  vim.api.nvim_buf_delete(b, { force = true })
end

local function marks(b)
  return vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })
end

local function find_conceal(ms, row, col)
  for _, m in ipairs(ms) do
    if m[2] == row and m[3] == col and m[4] and m[4].conceal then
      return m[4].conceal
    end
  end
  return nil
end

-- Basic header + rule + data: pipes get │, rule pipes get ├ ┤, plus gets ┼.
with_buf({
  "| col1 | col2 |",
  "|------+------|",
  "| a    | b    |",
}, function(b)
  local ms = marks(b)
  -- Row 0 (header) pipes at cols 0, 7, 14
  check("row 0 col 0 -> │", find_conceal(ms, 0, 0) == "│")
  check("row 0 col 7 -> │", find_conceal(ms, 0, 7) == "│")
  check("row 0 col 14 -> │", find_conceal(ms, 0, 14) == "│")
  -- Row 1 (rule): leftmost pipe -> ├, rightmost -> ┤, plus -> ┼
  check("row 1 col 0 -> ├ (teel)", find_conceal(ms, 1, 0) == "├")
  check("row 1 col 14 -> ┤ (teer)", find_conceal(ms, 1, 14) == "┤")
  check("row 1 col 7 -> ┼ (cross)", find_conceal(ms, 1, 7) == "┼")
  -- Some `-` becomes ─
  check("row 1 col 1 -> ─", find_conceal(ms, 1, 1) == "─")
  -- Row 2 (data) pipes
  check("row 2 col 0 -> │", find_conceal(ms, 2, 0) == "│")
end)

-- Alignment row: <l> -> ←, <r> -> →, <c> -> ·
with_buf({
  "| col1 | col2 | col3 |",
  "| <l>  | <r>  | <c>  |",
}, function(b)
  local ms = marks(b)
  -- The 3-char `<l>` / `<r>` / `<c>` markers conceal as arrows.
  local arrows = {}
  for _, m in ipairs(ms) do
    if m[4] and m[4].conceal and m[4].conceal:match("[←→·]") then
      arrows[m[4].conceal] = (arrows[m[4].conceal] or 0) + 1
    end
  end
  check("alignment row: ← present", (arrows["←"] or 0) >= 1)
  check("alignment row: → present", (arrows["→"] or 0) >= 1)
  check("alignment row: · present", (arrows["·"] or 0) >= 1)
end)

-- An uppercase marker and a width digit run are markers too, in the form
-- `org-table-align` recognises.
with_buf({
  "| col1 | col2  | col3 |",
  "| <R>  | <c12> | <L>  |",
}, function(b)
  local arrows = {}
  for _, m in ipairs(marks(b)) do
    if m[4] and m[4].conceal and m[4].conceal:match("[←→·]") then
      arrows[m[4].conceal] = (arrows[m[4].conceal] or 0) + 1
    end
  end
  check("uppercase <R> concealed", (arrows["→"] or 0) >= 1, vim.inspect(arrows))
  check("width-digit <c12> concealed", (arrows["·"] or 0) >= 1, vim.inspect(arrows))
  check("uppercase <L> concealed", (arrows["←"] or 0) >= 1, vim.inspect(arrows))
end)

-- Top + bottom virtual borders: 2 virt_lines extmarks per table.
with_buf({
  "| a | b |",
  "|---+---|",
  "| 1 | 2 |",
}, function(b)
  local ms = marks(b)
  local virts = 0
  for _, m in ipairs(ms) do
    if m[4] and m[4].virt_lines then
      virts = virts + 1
    end
  end
  check("border_virtual: top + bottom present", virts == 2, "got " .. virts)
end)

-- preset = "round": top corners ╭╮, bottom ╰╯
do
  require("organ").config.modern.table = { preset = "round", border_virtual = true }
  with_buf({
    "| a |",
    "| 1 |",
  }, function(b)
    local ms = marks(b)
    -- Find the virt_lines and inspect first / last char of each.
    local top, bot
    for _, m in ipairs(ms) do
      if m[4] and m[4].virt_lines then
        local text = m[4].virt_lines[1][1][1]
        if m[4].virt_lines_above then
          top = text
        else
          bot = text
        end
      end
    end
    check("round preset: top has ╭", top and top:find("╭") ~= nil, "got " .. tostring(top))
    check("round preset: top has ╮", top and top:find("╮") ~= nil)
    check("round preset: bot has ╰", bot and bot:find("╰") ~= nil)
    check("round preset: bot has ╯", bot and bot:find("╯") ~= nil)
  end)
  require("organ").config.modern.table = { border_virtual = true }
end

-- Non-table content: no extmarks placed.
with_buf({
  "* H1",
  "regular paragraph",
  "more text",
}, function(b)
  local ms = marks(b)
  check("non-table content: no extmarks", #ms == 0, "got " .. #ms)
end)

-- modern.table = false: refresh is a no-op.
do
  local saved = require("organ").config.modern.table
  require("organ").config.modern.table = false
  with_buf({ "| a | b |", "| 1 | 2 |" }, function(b)
    local ms = marks(b)
    check("modern.table=false: no extmarks", #ms == 0, "got " .. #ms)
  end)
  require("organ").config.modern.table = saved
end

if fails > 0 then
  print()
  print(("FAILED %d checks"):format(fails))
  os.exit(1)
end
print()
print("modern_table_test: PASS")
os.exit(0)
