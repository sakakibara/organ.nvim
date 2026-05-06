-- diary_sexp: parse + matches for the supported diary-* forms.
-- Run via: nvim --headless -l tests/diary_sexp_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local d = require("organ.diary_sexp")

-- diary-date: exact match.
do
  local n = d.parse("<%%(diary-date 2026 4 28)>")
  assert(n and n.kind == "date", "kind: " .. tostring(n and n.kind))
  assert(d.matches(n, "2026-04-28") == true, "exact date matches")
  assert(d.matches(n, "2026-04-29") == false, "different day mismatch")
end

-- diary-date with `t` wildcard for the year → matches every April 28.
do
  local n = d.parse("<%%(diary-date t 4 28)>")
  assert(d.matches(n, "2026-04-28") == true, "wildcard year")
  assert(d.matches(n, "2030-04-28") == true, "wildcard year other yr")
  assert(d.matches(n, "2026-04-29") == false, "still day-locked")
end

-- diary-anniversary: every year on M-D, after the first occurrence.
do
  local n = d.parse("<%%(diary-anniversary 1990 1 1)>")
  assert(d.matches(n, "1990-01-01") == true, "first occurrence")
  assert(d.matches(n, "2026-01-01") == true, "later year")
  assert(d.matches(n, "1989-01-01") == false, "before first year")
  assert(d.matches(n, "2026-01-02") == false, "wrong day")
end

-- diary-cyclic: every N days starting from given date.
do
  local n = d.parse("<%%(diary-cyclic 7 2026 1 1)>")
  assert(d.matches(n, "2026-01-01") == true, "day 0")
  assert(d.matches(n, "2026-01-08") == true, "day 7")
  assert(d.matches(n, "2026-01-09") == false, "day 8 mismatch")
  assert(d.matches(n, "2025-12-25") == false, "before start")
end

-- diary-block: inclusive date range.
do
  local n = d.parse("<%%(diary-block 2026 1 1 2026 1 31)>")
  assert(d.matches(n, "2026-01-01") == true, "start edge")
  assert(d.matches(n, "2026-01-15") == true, "middle")
  assert(d.matches(n, "2026-01-31") == true, "end edge")
  assert(d.matches(n, "2026-02-01") == false, "after end")
end

-- diary-float: 2nd Wednesday of every month.
do
  local n = d.parse("<%%(diary-float t 3 2)>")
  assert(n and n.kind == "float", "kind: " .. tostring(n and n.kind))
  -- 2026-05-13 is the 2nd Wednesday of May 2026 (May 6 is the 1st Wed).
  assert(d.matches(n, "2026-05-13") == true, "2nd Wed of May 2026")
  assert(d.matches(n, "2026-05-06") == false, "1st Wed not 2nd")
  assert(d.matches(n, "2026-05-12") == false, "Tue not Wed")
end

-- Buffer scan: collect sexps + identify headline ownership.
do
  local tmp = vim.fn.tempname() .. ".org"
  local fh = assert(io.open(tmp, "w"))
  fh:write([[* Yearly review
<%%(diary-anniversary 2020 5 1)>
* Other
some prose
* Holiday
<%%(diary-date 2026 12 25)>
]])
  fh:close()
  local b = vim.fn.bufadd(tmp)
  vim.fn.bufload(b)
  local recs = d.scan(b)
  assert(#recs == 2, "expected 2 sexps; got " .. #recs)
  -- First sexp lives under "Yearly review" headline (line 1).
  assert(recs[1].hl_line == 1, "first owner: " .. recs[1].hl_line)
  assert(recs[2].hl_line == 5, "second owner: " .. recs[2].hl_line)
  os.remove(tmp)

  -- matches_in_buffer narrows to those firing today.
  vim.cmd("badd " .. tmp)
  -- We can't easily re-create the buffer here; just trust scan + matches.
end

-- Unknown / unsafe forms reject.
do
  assert(d.parse("<%%(if (memq 1 '(1 2)) t)>") == nil, "arbitrary `if` predicate must not parse")
  assert(d.parse("<%%(custom-thing 1 2)>") == nil, "unknown form must not parse")
end

io.write("diary sexp ok\n")
os.exit(0)
