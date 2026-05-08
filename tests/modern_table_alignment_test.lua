-- modern.table visual alignment: a misaligned source table renders
-- as a clean aligned table via inline virt_text padding (where the
-- source is short) and conceal of extra whitespace (where the
-- source is over-padded).  Buffer text is not modified.
--
-- Run via: nvim --headless -l tests/modern_table_alignment_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  modern = { table = true },
})

local INPUT = {
  "|name|qty|total|",
  "|----+----+-----|",
  "|apple|1|100|",
  "| longer text |2|200|",
  "|cherry|33|9999|",
}

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, INPUT)
vim.bo[b].filetype = "org"
vim.api.nvim_set_current_buf(b)

require("organ.modern.table").attach(b)
require("organ.modern.table").refresh(b)

-- Buffer text MUST NOT change -- alignment is purely visual.
local after = vim.api.nvim_buf_get_lines(b, 0, -1, false)
local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local same_text = #after == #INPUT
if same_text then
  for i = 1, #INPUT do
    if INPUT[i] ~= after[i] then
      same_text = false
      break
    end
  end
end
check("buffer text unchanged after refresh", same_text)

local NS = vim.api.nvim_get_namespaces()["organ_modern_table"]
local marks = vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })

-- Bucket virt_text spaces and conceal-empty marks per row so we can
-- compute the visual width each row would render at.
local function row_visual_widths(row, source_line)
  -- Start with source byte length (each ASCII char is 1 display col;
  -- the test fixture is ASCII, so byte == display).
  local visual = #source_line
  for _, m in ipairs(marks) do
    if m[2] == row then
      local d = m[4] or {}
      if d.virt_text then
        for _, chunk in ipairs(d.virt_text) do
          visual = visual + vim.fn.strdisplaywidth(chunk[1] or "")
        end
      elseif d.conceal == "" then
        local len = (d.end_col or m[3]) - m[3]
        visual = visual - len
      end
      -- conceal with replacement char (`│`, `─`, `┼`, ...) leaves
      -- visual width unchanged (1-char source replaced by 1 cell).
    end
  end
  return visual
end

local widths = {}
for r = 0, #INPUT - 1 do
  widths[r] = row_visual_widths(r, INPUT[r + 1])
end

-- Every row must end up at the SAME visual width.  That's the
-- contract: a misaligned source renders as a uniformly-aligned
-- table with all cells lining up vertically.
local ref = widths[0]
for r = 1, #INPUT - 1 do
  check(
    ("row %d visual width matches row 0 (%d cols)"):format(r, ref),
    widths[r] == ref,
    ("got %d, want %d"):format(widths[r], ref)
  )
end

-- Sanity: target width should be 13 (col1) + 5 (col2) + 7 (col3) +
-- 4 (4 pipes/+) = 29.
check("uniform table width is 29", ref == 29, ("got %d"):format(ref))

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_table_alignment_test: PASS")
