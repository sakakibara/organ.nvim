-- diary_sexp: parse + matches for the supported diary-* / org-* forms.
-- `diary-*` take Emacs's default `calendar-date-style` (american: M D Y);
-- `org-*` take the fixed ISO order (Y M D).
-- Run via: nvim --headless -l tests/diary_sexp_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local d = require("organ.diary_sexp")

-- diary-date: exact match.
do
  local n = d.parse("<%%(diary-date 4 28 2026)>")
  assert(n and n.kind == "date", "kind: " .. tostring(n and n.kind))
  assert(d.matches(n, "2026-04-28") == true, "exact date matches")
  assert(d.matches(n, "2026-04-29") == false, "different day mismatch")
  assert(d.matches(d.parse("<%%(org-date 2026 4 28)>"), "2026-04-28") == true, "org-date Y M D")
end

-- diary-date with `t` wildcard for the year -> matches every April 28.
do
  local n = d.parse("<%%(diary-date 4 28 t)>")
  assert(d.matches(n, "2026-04-28") == true, "wildcard year")
  assert(d.matches(n, "2030-04-28") == true, "wildcard year other yr")
  assert(d.matches(n, "2026-04-29") == false, "still day-locked")
  assert(d.matches(d.parse("<%%(diary-date t 28 2026)>"), "2026-05-28") == true, "wildcard month")
end

-- A leading year stays the year when the trailing values are wildcards.
do
  local n = d.parse("<%%(diary-date 2026 t t)>")
  assert(n and n.y == 2026 and n.m == "t" and n.d == "t", "Y t t parsed: " .. vim.inspect(n))
  assert(d.matches(n, "2026-05-05") == true, "Y t t: any day of that year")
  assert(d.matches(n, "2027-05-05") == false, "Y t t: other year")
  local nm = d.parse("<%%(diary-date 2026 5 t)>")
  assert(nm and nm.y == 2026 and nm.m == 5 and nm.d == "t", "Y M t parsed: " .. vim.inspect(nm))
  assert(d.matches(nm, "2026-05-20") == true, "Y M t: any day of that month")
  assert(d.matches(nm, "2026-06-05") == false, "Y M t: other month")
  assert(d.matches(d.parse("<%%(diary-date t 5 t)>"), "2027-11-05") == true, "t D t: day only")
end

-- diary-anniversary: every year on M-D, strictly after the starting year.
do
  local n = d.parse("<%%(diary-anniversary 1 1 1990)>")
  assert(d.matches(n, "1990-01-01") == false, "starting year itself does not fire")
  assert(d.matches(n, "1991-01-01") == true, "first anniversary")
  assert(d.matches(n, "2026-01-01") == true, "later year")
  assert(d.matches(n, "1989-01-01") == false, "before first year")
  assert(d.matches(n, "2026-01-02") == false, "wrong day")
  local ny = d.parse("<%%(diary-anniversary 5 14)>")
  assert(ny and d.matches(ny, "2026-05-14") == true, "year is optional")
  local o = d.parse("<%%(org-anniversary 1956 5 14)>")
  assert(o and d.matches(o, "2026-05-14") == true, "org-anniversary Y M D")
  assert(d.matches(o, "1956-05-14") == false, "org-anniversary starting year")
end

-- diary-* forms also accept the iso order (Y M D): a leading value that
-- cannot be a month is the year.
do
  local a = d.parse("<%%(diary-anniversary 1956 5 14)>")
  assert(a and a.y == 1956 and a.m == 5 and a.d == 14, "diary-anniversary Y M D")
  local dt = d.parse("<%%(diary-date 2026 12 25)>")
  assert(dt and d.matches(dt, "2026-12-25") == true, "diary-date Y M D")
  local wy = d.parse("<%%(diary-date t 4 28)>")
  assert(wy and d.matches(wy, "2030-04-28") == true, "diary-date t M D (wildcard year first)")
  assert(d.matches(wy, "2030-04-29") == false, "wildcard year first still day-locked")
  local wa = d.parse("<%%(diary-date 4 28 t)>")
  assert(wa and d.matches(wa, "2030-04-28") == true, "diary-date M D t (wildcard year last)")
  local wm = d.parse("<%%(diary-date t 28 2026)>")
  assert(wm and d.matches(wm, "2026-07-28") == true, "diary-date t D Y (wildcard month)")
  local c = d.parse("<%%(diary-cyclic 7 2026 1 5)>")
  assert(c and d.matches(c, "2026-01-12") == true, "diary-cyclic N Y M D")
  local blk = d.parse("<%%(diary-block 2026 3 1 2026 3 3)>")
  assert(blk and d.matches(blk, "2026-03-02") == true, "diary-block Y M D twice")
  assert(d.matches(blk, "2026-03-04") == false, "diary-block end")
end

-- diary-cyclic: every N days starting from given date.
do
  local n = d.parse("<%%(diary-cyclic 7 1 1 2026)>")
  assert(d.matches(n, "2026-01-01") == true, "day 0")
  assert(d.matches(n, "2026-01-08") == true, "day 7")
  assert(d.matches(n, "2026-01-09") == false, "day 8 mismatch")
  assert(d.matches(n, "2025-12-25") == false, "before start")
  local o = d.parse("<%%(org-cyclic 7 2026 1 1)>")
  assert(o and d.matches(o, "2026-01-08") == true, "org-cyclic N Y M D")
end

-- diary-block: inclusive date range.
do
  local n = d.parse("<%%(diary-block 1 1 2026 1 31 2026)>")
  assert(d.matches(n, "2026-01-01") == true, "start edge")
  assert(d.matches(n, "2026-01-15") == true, "middle")
  assert(d.matches(n, "2026-01-31") == true, "end edge")
  assert(d.matches(n, "2026-02-01") == false, "after end")
  local o = d.parse("<%%(org-block 2026 1 1 2026 1 31)>")
  assert(o and d.matches(o, "2026-01-15") == true, "org-block Y M D Y M D")
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
<%%(diary-anniversary 5 1 2020)>
* Other
some prose
* Holiday
<%%(diary-date 12 25 2026)>
]])
  fh:close()
  local b = vim.fn.bufadd(tmp)
  vim.fn.bufload(b)
  local recs = d.scan(b)
  assert(#recs == 2, "expected 2 sexps; got " .. #recs)
  -- First sexp lives under "Yearly review" headline (line 1).
  assert(recs[1].hl_line == 1, "first owner: " .. recs[1].hl_line)
  assert(recs[2].hl_line == 5, "second owner: " .. recs[2].hl_line)
  assert(#d.matches_in_buffer(b, "2026-12-25") == 1, "matches_in_buffer on the holiday")
  assert(#d.matches_in_buffer(b, "2026-05-01") == 1, "matches_in_buffer on the anniversary")
  assert(#d.matches_in_buffer(b, "2026-05-02") == 0, "matches_in_buffer off-day")
  os.remove(tmp)
end

-- Unknown / unsafe forms reject.
do
  assert(d.parse("<%%(if (memq 1 '(1 2)) t)>") == nil, "arbitrary `if` predicate must not parse")
  assert(d.parse("<%%(custom-thing 1 2)>") == nil, "unknown form must not parse")
end

io.write("diary sexp ok\n")
os.exit(0)
