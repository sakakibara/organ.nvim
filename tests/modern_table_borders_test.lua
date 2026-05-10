-- Modern table virtual borders (top `┌──┬──┐` / bottom `└──┴──┘`) must
-- align with the data-row layout the alignment pass produces, NOT with
-- the source pipe positions of the first/last row.  When the source is
-- misaligned, those two layouts differ -- the old behavior built the
-- border off `pipe_positions(first_line)`, leaving the border narrower
-- (or wider) than the visually-padded data rows.
--
-- Contract: border display width == sum of (col_width + 2) per column,
-- plus n+1 corner/tee chars.
--
-- Run via: nvim --headless -l tests/modern_table_borders_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  modern = { table = true },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local NS = vim.api.nvim_create_namespace("organ_modern_table")

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
-- Misaligned source: first row's pipes at very different byte
-- positions from the longest row.
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "| a | b |",
  "| longvalue | extra |",
  "| s | longestcell |",
})
vim.bo[b].filetype = "org"
vim.cmd("doautocmd FileType org")
require("organ.modern.table").attach(b)
require("organ.modern.table").refresh(b)

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Pull virt_lines from the first and last rows.
local function virt_line_width(row)
  local marks = vim.api.nvim_buf_get_extmarks(b, NS, { row, 0 }, { row, -1 }, { details = true })
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    if d.virt_lines then
      local total = 0
      for _, seg in ipairs(d.virt_lines[1] or {}) do
        total = total + vim.fn.strdisplaywidth(seg[1] or "")
      end
      if total > 0 then
        return total
      end
    end
  end
  return 0
end

-- Expected widths: column 1 longest content "longvalue" (9 chars),
-- column 2 longest "longestcell" (11 chars).  Cell padding adds 2
-- per column ("` content `").  Plus 3 corner/tee chars.
--   1 (┌/└) + (9+2) + 1 (┬/┴) + (11+2) + 1 (┐/┘) = 27
local expected = 1 + 11 + 1 + 13 + 1
local top_w = virt_line_width(0)
local bot_w = virt_line_width(2)

check(
  ("top border width = %d (sized to aligned column widths)"):format(expected),
  top_w == expected,
  ("got %d"):format(top_w)
)
check(("bottom border width = %d"):format(expected), bot_w == expected, ("got %d"):format(bot_w))
check(
  "top and bottom borders have the same width",
  top_w == bot_w,
  ("top=%d bot=%d"):format(top_w, bot_w)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_table_borders_test: PASS")
os.exit(0)
