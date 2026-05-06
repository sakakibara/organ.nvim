-- Asserts the convenience wrappers delegate to headlines() with expected filters.
-- Run via: nvim --headless -l tests/query_conv_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local db_path = tmp .. "/c.db"
local org_dir = tmp .. "/org"
vim.fn.mkdir(org_dir, "p")
for _, name in ipairs({ "01-headlines.org", "02-planning.org", "03-properties.org", "04-dates.org" }) do
  vim.fn.system({ "cp", root .. "/tests/fixtures/" .. name, org_dir .. "/" .. name })
end
require("organ").setup({
  db_path = db_path,
  org_dir = org_dir,
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
})
require("organ").scan_blocking(org_dir, 5000)

local query = require("organ.query")

-- agenda: scheduled or deadline in window
do
  local rows = query.agenda({
    from = "2026-04-24",
    to = "2026-05-05",
    types = { "scheduled", "deadline" },
  })
  assert(#rows > 0, "expected at least one agenda item")
  for _, r in ipairs(rows) do
    local sd = r.scheduled_date or ""
    local dd = r.deadline_date or ""
    local in_sched = sd:sub(1, 10) >= "2026-04-24" and sd:sub(1, 10) <= "2026-05-05"
    local in_dead = dd:sub(1, 10) >= "2026-04-24" and dd:sub(1, 10) <= "2026-05-05"
    assert(in_sched or in_dead, string.format("neither in window: %s / %s", sd, dd))
  end
end

-- agenda with types = {"scheduled"} only
do
  local rows = query.agenda({ from = "2026-04-24", to = "2026-05-05", types = { "scheduled" } })
  for _, r in ipairs(rows) do
    assert(r.scheduled_date ~= nil, "scheduled-only should never yield rows without scheduled_date")
  end
end

-- by_tag
do
  local rows = query.by_tag({ "work" })
  assert(#rows > 0)
  for _, r in ipairs(rows) do
    local has = false
    for _, t in ipairs(r.tags) do
      if t == "work" then
        has = true
        break
      end
    end
    assert(has, "expected tag 'work' on every row")
  end
end

-- by_todo
do
  local rows = query.by_todo({ "TODO" })
  for _, r in ipairs(rows) do
    assert(r.todo_state == "TODO")
  end
  assert(#rows > 0)
end

-- by_file — returns ordered by line_start
do
  local path = org_dir .. "/01-headlines.org"
  local canon = require("organ.path").canonical(path)
  local rows = query.by_file(path)
  for _, r in ipairs(rows) do
    assert(r.file_path == canon)
  end
  for i = 1, #rows - 1 do
    assert(rows[i].line_start <= rows[i + 1].line_start, "not sorted by line_start")
  end
end

vim.fn.delete(tmp, "rf")
io.write("query conv ok\n")
os.exit(0)
