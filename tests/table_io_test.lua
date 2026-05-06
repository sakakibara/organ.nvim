-- table_io: parse_csv, emit_csv, parse_org_table, render_org_table,
-- import + export round-trip.
-- Run via: nvim --headless -l tests/table_io_test.lua

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

-- 1. parse_csv: simple, quoted, empty cells, embedded commas.
do
  local rows = tio.parse_csv('a,b,c\n1,"two,2",3\n,5,\n')
  assert(#rows == 3, "row count: " .. #rows)
  assert(rows[1][1] == "a", "header[1]")
  assert(rows[2][2] == "two,2", "embedded comma cell: " .. rows[2][2])
  assert(rows[3][1] == "" and rows[3][3] == "", "leading/trailing empty cells")
end

-- 2. emit_csv: quotes cells with commas / quotes / newlines.
do
  local out = tio.emit_csv({ { "plain", "with,comma", 'has "quote"' } })
  -- Expected: "plain","with,comma","has ""quote"""... (only quoted as needed)
  assert(out:find("plain", 1, true), "plain cell")
  assert(out:find('"with,comma"', 1, true), "comma cell quoted")
  assert(out:find('"has ""quote"""', 1, true), "quote doubled and wrapped")
end

-- 3. parse_org_table reads cells, ignores divider rows.
do
  local lines = {
    "| name | age |",
    "|------+-----|",
    "| ada  |  36 |",
    "| ben  |  41 |",
  }
  local rows = tio.parse_org_table(lines, 1)
  assert(rows and #rows == 3, "expected 3 data rows; got " .. (rows and #rows or 0))
  assert(rows[1][1] == "name" and rows[1][2] == "age", "header parsed")
  assert(rows[2][1] == "ada" and rows[2][2] == "36", "row 2 parsed")
end

-- 4. render_org_table emits a divider after the header.
do
  local lines = tio.render_org_table({
    { "h1", "h2" },
    { "a", "b" },
  })
  assert(#lines == 3, "3 lines; got " .. #lines)
  assert(lines[2]:match("^|%-"), "divider on line 2: " .. lines[2])
end

-- 5. End-to-end import/export round-trip via files.
do
  local tmp = vim.fn.tempname()
  local csv = tmp .. ".csv"
  local fh = assert(io.open(csv, "w"))
  fh:write("name,age\nada,36\nben,41\n")
  fh:close()

  -- Import into a fresh buffer.
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { "" })
  local n = tio.import(b, 1, csv)
  assert(n == 3, "imported rows: " .. tostring(n))
  local body = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- First inserted line is the header row.
  assert(body[1]:match("^| name"), "first line is org header: " .. body[1])

  -- Export back to TSV; sniffs header row.
  local tsv = tmp .. ".tsv"
  local m = tio.export(b, 1, tsv)
  assert(m == 3, "exported rows: " .. tostring(m))
  local out = io.open(tsv, "r"):read("*a")
  -- Tab delimiter expected.
  assert(out:find("\t", 1, true), "tsv should use tab delimiter:\n" .. out)
  assert(out:find("ada", 1, true), "ada present")

  os.remove(csv)
  os.remove(tsv)
end

io.write("table io ok\n")
os.exit(0)
