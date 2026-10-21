-- tests/conformance/_signatures.lua: the expected-divergence checker must
-- fail on every way a gate could otherwise pass vacuously.

local root = vim.fn.getcwd()
local sig = dofile(root .. "/tests/conformance/_signatures.lua")

local failures = 0
local function check(name, cond)
  if not cond then
    failures = failures + 1
    io.write("FAIL: " .. name .. "\n")
  end
end

local function write(lines)
  local path = vim.fn.tempname()
  vim.fn.writefile(lines, path)
  return path
end

local hunk = "-H\t1\t\tA\t\tx\n+H\t1\t\t\t\t[#A] x"
local row = sig.row("a.org", "PR-2", "KEEP", 1, hunk)

local rows = sig.load(write({ "# comment", "", row }))
check("loads one row", #rows == 1 and rows[1].hunk == hunk and rows[1].count == 1)

check("exact match passes", #sig.check({ ["a.org"] = { hunk } }, rows) == 0)
check("same hunk in another case is unkeyed", #sig.check({ ["b.org"] = { hunk } }, rows) == 2)
check("stale row fails", #sig.check({}, rows) == 1)
check("extra occurrence fails", #sig.check({ ["a.org"] = { hunk, hunk } }, rows) == 1)
check("unkeyed hunk fails", #sig.check({ ["a.org"] = { hunk, "-other" } }, rows) == 1)

local unkeyed = sig.check({ ["a.org"] = { "-x\ty" } }, {})
check("unkeyed report is a ready row", unkeyed[1] == "unkeyed difference: a.org\t?\t?\t1\t-x\\ty")

check("duplicate row rejected", not pcall(sig.load, write({ row, row })))
check(
  "unknown class rejected",
  not pcall(sig.load, write({ sig.row("a.org", "X-1", "MAYBE", 1, "-x") }))
)
check("malformed row rejected", not pcall(sig.load, write({ "a.org\tPR-2\tKEEP" })))

local back = "a\\b\tc\nd"
check("escape round-trips", sig.load(write({ sig.row("c", "I", "KEEP", 1, back) }))[1].hunk == back)

-- A hunk carries the nearest non-blank line above it, so dropping the
-- blank under B is not the recorded drop of the blank under A.
local emacs_lines = { "* A", "", "body a", "* B", "", "body b" }
local under_a = sig.hunks(emacs_lines, { "* A", "body a", "* B", "", "body b" })
local under_b = sig.hunks(emacs_lines, { "* A", "", "body a", "* B", "body b" })
check("context names the place", under_a[1] == " * A\n-" and under_b[1] == " * B\n-")
check("a moved difference is unkeyed", #sig.check({ ["a.org"] = under_b }, {
  { case = "a.org", id = "X", class = "KEEP", count = 1, hunk = under_a[1], line = 1 },
}) == 2)
check("a hunk at the top has the start context", sig.hunks({ "x" }, { "y", "x" })[1] == "^\n+y")

if failures > 0 then
  os.exit(1)
end
io.write("conformance signatures ok\n")
