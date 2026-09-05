-- query.agenda over more than one date type is one result set: the
-- configured order and the limit apply to the merge, not to each type.
-- Run via: nvim --headless -l tests/query_agenda_order_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

require("organ").setup({
  org_dir = tmp,
  db_path = tmp .. "/organ.db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local h = require("organ").db_handle()
h:exec([[
  INSERT INTO files(path, mtime, hash, indexed) VALUES ('/x.org', 0, 'a', 0);
  INSERT INTO headlines(id, file_path, level, title, scheduled_date, deadline_date, line_start, line_end) VALUES
    ('s1', '/x.org', 1, 'S1', '2026-05-04', NULL,         0, 1),
    ('d1', '/x.org', 1, 'D1', NULL,         '2026-05-05', 2, 3),
    ('s2', '/x.org', 1, 'S2', '2026-05-06', NULL,         4, 5),
    ('d2', '/x.org', 1, 'D2', NULL,         '2026-05-07', 6, 7),
    ('s3', '/x.org', 1, 'S3', '2026-05-08', NULL,         8, 9),
    ('b1', '/x.org', 1, 'B1', '2026-05-04', '2026-05-08', 10, 11);
]])

local query = require("organ.query")

local function titles(opts)
  local out = {}
  for _, r in ipairs(query.agenda(opts)) do
    out[#out + 1] = r.title
  end
  return table.concat(out, ",")
end

local week = { from = "2026-05-04", to = "2026-05-10", types = { "scheduled", "deadline" } }

-- Date order across both types, not all-scheduled-then-all-deadline.
assert(titles(week) == "B1,S1,D1,S2,D2,S3", "order: " .. titles(week))

-- The limit bounds the merged set.
local limited = vim.tbl_extend("force", week, { limit = 3 })
assert(titles(limited) == "B1,S1,D1", "limit: " .. titles(limited))

-- A row carrying both dates appears once.
local narrow = { from = "2026-05-04", to = "2026-05-04", types = { "scheduled", "deadline" } }
assert(titles(narrow) == "B1,S1", "boundary: " .. titles(narrow))

-- An inverted window still matches nothing.
local empty = { from = "2026-05-06", to = "2026-05-05", types = { "scheduled", "deadline" } }
assert(titles(empty) == "", "inverted window: " .. titles(empty))

-- Single-type queries are unchanged.
assert(
  titles({ from = "2026-05-04", to = "2026-05-10", types = { "scheduled" } }) == "B1,S1,S2,S3",
  "scheduled only: " .. titles({ from = "2026-05-04", to = "2026-05-10", types = { "scheduled" } })
)

vim.fn.delete(tmp, "rf")
io.write("query agenda order ok\n")
os.exit(0)
