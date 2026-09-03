-- render_org_table must reproduce Emacs `org-table-align` byte for byte,
-- so an imported table is already a `:Org format` fixpoint.
--
-- Every expected block below is verbatim Emacs output, captured with
--   emacs --batch -Q -l org --eval '(progn (org-mode) (org-table-align))'
-- over the same rows.
--
-- Run via: nvim --headless -l tests/table_io_align_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local tio = require("organ.table_io")

local fails = 0

local function check(label, got, want)
  if #got == #want then
    local same = true
    for i = 1, #got do
      if got[i] ~= want[i] then
        same = false
        break
      end
    end
    if same then
      io.write("PASS  " .. label .. "\n")
      return
    end
  end
  fails = fails + 1
  io.write("FAIL  " .. label .. "\n")
  io.write("  got:\n")
  for _, l in ipairs(got) do
    io.write(string.format("    %q\n", l))
  end
  io.write("  want:\n")
  for _, l in ipairs(want) do
    io.write(string.format("    %q\n", l))
  end
end

-- A numeric column right-aligns: at least `org-table-number-fraction`
-- of its non-empty cells match `org-table-number-regexp`.
check(
  "numeric columns right-align",
  tio.render_org_table({
    { "name", "qty", "total" },
    { "apple", "1", "100" },
    { "banana", "2", "200" },
    { "cherry", "33", "9999" },
  }),
  {
    "| name   | qty | total |",
    "|--------+-----+-------|",
    "| apple  |   1 |   100 |",
    "| banana |   2 |   200 |",
    "| cherry |  33 |  9999 |",
  }
)

-- `<l>` / `<r>` / `<c>` fix a column's alignment from any row, and the
-- marker cell is padded like every other cell in its column.
check(
  "markers fix alignment from a body row",
  tio.render_org_table({
    { "a", "b", "c" },
    { "<r>", "<c>", "<l>" },
    { "xxxxx", "1", "2" },
    { "yyyyy", "3", "4" },
  }),
  {
    "|     a |  b  | c   |",
    "|-------+-----+-----|",
    "|   <r> | <c> | <l> |",
    "| xxxxx |  1  | 2   |",
    "| yyyyy |  3  | 4   |",
  }
)

-- `<R>` is recognized as a marker (so the numeric column is not
-- right-aligned) yet pads left -- Emacs matches the marker regexp
-- case-insensitively but only branches on lowercase in the padder.
check(
  "uppercase marker fixes the column but pads left",
  tio.render_org_table({
    { "a", "b" },
    { "<R>", "<r>" },
    { "1", "1" },
    { "22222", "22222" },
  }),
  {
    "| a     |     b |",
    "|-------+-------|",
    "| <R>   |   <r> |",
    "| 1     |     1 |",
    "| 22222 | 22222 |",
  }
)

-- A marker may carry a width digit, and an all-empty column is one
-- column wide, not zero.
check(
  "marker width digits and the one-column floor",
  tio.render_org_table({
    { "a", "b", "c" },
    { "<r5>", "", "1" },
    { "xx", "", "2" },
  }),
  {
    "|    a | b | c |",
    "|------+---+---|",
    "| <r5> |   | 1 |",
    "|   xx |   | 2 |",
  }
)

-- Rendering is a fixpoint: reading a rendered table back and rendering
-- it again reproduces it exactly.
do
  local rows = {
    { "name", "qty", "total" },
    { "apple", "1", "100" },
    { "<r>", "2", "200" },
    { "cherry", "33", "9999" },
  }
  local once = tio.render_org_table(rows)
  local twice = tio.render_org_table(tio.parse_org_table(once, 1))
  check("render is its own fixpoint", twice, once)
end

-- An imported table must survive `:Org format` untouched.
do
  local function table_lines(bufnr)
    local out = {}
    for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:match("^%s*|") then
        out[#out + 1] = l
      end
    end
    return out
  end
  local csv = vim.fn.tempname() .. ".csv"
  local fh = assert(io.open(csv, "w"))
  fh:write("name,qty,total\napple,1,100\nbanana,2,200\ncherry,33,9999\n")
  fh:close()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "" })
  vim.bo[b].filetype = "org"
  assert(tio.import(b, 1, csv), "import failed")
  local imported = table_lines(b)
  require("organ.format").format_buffer(b)
  check("import is a :Org format fixpoint", table_lines(b), imported)
  os.remove(csv)
end

if fails > 0 then
  io.write("FAILED " .. fails .. " checks\n")
  os.exit(1)
end
io.write("table io align ok\n")
os.exit(0)
