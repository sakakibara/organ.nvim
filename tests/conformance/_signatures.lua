-- Expected-divergence signatures for the Emacs conformance gates.
--
-- A signatures file is TSV, one row per expected difference:
--
--   case <TAB> id <TAB> class <TAB> count <TAB> hunk
--
-- `case` names the corpus file, `id` the divergence-inventory entry that
-- rules on the difference, `class` one of KEEP / TARGET / INHERENT /
-- TRANSITIONAL, `count` how many times the hunk occurs in that case, and
-- `hunk` the exact difference with `\n`, `\t` and `\\` escaped.  A hunk's
-- first line is its context: " " and the nearest non-blank line of the
-- first text above the difference, or "^" when there is none, so the same
-- change at another place is a different hunk.  Lines starting with `#`
-- and blank lines are ignored.
--
-- check() fails on a hunk no row covers, on a row whose hunk occurs a
-- different number of times than recorded (a stale row included), and on
-- rows that are malformed or duplicate one another.

local M = {}

local CLASSES = { KEEP = true, TARGET = true, INHERENT = true, TRANSITIONAL = true }

local function escape(s)
  return (s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\t", "\\t"))
end

local function unescape(s)
  return (s:gsub("\\(.)", { n = "\n", t = "\t", ["\\"] = "\\" }))
end

M.escape = escape

--- Read a signatures file; returns the rows or raises on a malformed one.
function M.load(path)
  local rows, seen = {}, {}
  local lnum = 0
  for line in io.lines(path) do
    lnum = lnum + 1
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local case, id, class, count, hunk = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t(.+)$")
      if not case then
        error(string.format("%s:%d: malformed signature row", path, lnum))
      end
      if not CLASSES[class] then
        error(string.format("%s:%d: unknown class %s", path, lnum, class))
      end
      local key = case .. "\0" .. hunk
      if seen[key] then
        error(string.format("%s:%d: duplicates line %d", path, lnum, seen[key]))
      end
      seen[key] = lnum
      rows[#rows + 1] = {
        case = case,
        id = id,
        class = class,
        count = tonumber(count),
        hunk = unescape(hunk),
        line = lnum,
      }
    end
  end
  return rows
end

--- Hunks of a line diff from line list `a` to line list `b`.
function M.hunks(a, b)
  local out = {}
  local ta, tb = table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n"
  for _, h in ipairs(vim.diff(ta, tb, { result_type = "indices" })) do
    local c = h[2] > 0 and h[1] - 1 or h[1]
    while c >= 1 and a[c]:match("^%s*$") do
      c = c - 1
    end
    local parts = { c >= 1 and (" " .. a[c]) or "^" }
    for i = h[1], h[1] + h[2] - 1 do
      parts[#parts + 1] = "-" .. a[i]
    end
    for i = h[3], h[3] + h[4] - 1 do
      parts[#parts + 1] = "+" .. b[i]
    end
    out[#out + 1] = table.concat(parts, "\n")
  end
  return out
end

--- Format a hunk as a signature row, for triaging a new difference.
function M.row(case, id, class, count, hunk)
  return table.concat({ case, id, class, tostring(count), escape(hunk) }, "\t")
end

--- Compare observed hunks against signature rows.
--- `observed` maps case -> list of hunk texts (duplicates allowed).
--- Returns a list of problems; empty means the gate passes.
function M.check(observed, rows)
  local problems = {}
  local counts = {}
  for case, hunks in pairs(observed) do
    for _, h in ipairs(hunks) do
      local key = case .. "\0" .. h
      counts[key] = (counts[key] or 0) + 1
    end
  end
  local covered = {}
  for _, r in ipairs(rows) do
    local key = r.case .. "\0" .. r.hunk
    covered[key] = true
    local n = counts[key] or 0
    if n ~= r.count then
      problems[#problems + 1] = string.format(
        "signature line %d (%s %s, %s) expects %d occurrence(s), saw %d",
        r.line,
        r.id,
        r.class,
        r.case,
        r.count,
        n
      )
    end
  end
  local unkeyed = {}
  for key, n in pairs(counts) do
    if not covered[key] then
      local case, hunk = key:match("^(.-)%z(.*)$")
      unkeyed[#unkeyed + 1] = M.row(case, "?", "?", n, hunk)
    end
  end
  table.sort(unkeyed)
  for _, u in ipairs(unkeyed) do
    problems[#problems + 1] = "unkeyed difference: " .. u
  end
  return problems
end

return M
