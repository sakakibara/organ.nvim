-- Verifies organ.duration (org-duration.el's API): duration predicates,
-- parsing, formatting, error messages and the range refusal.
-- Run via: nvim --headless -l tests/duration_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local D = require("organ.duration")

local function eq(got, want, what)
  assert(
    got == want,
    string.format("%s: got %s, want %s", what, vim.inspect(got), vim.inspect(want))
  )
end

local function minutes(s, want, canonical)
  local got, err = D.to_minutes(s, canonical)
  eq(err, nil, "to_minutes " .. vim.inspect(s) .. " error")
  eq(got, want, "to_minutes " .. vim.inspect(s))
end

local function to_error(s, want, canonical)
  local got, err = D.to_minutes(s, canonical)
  eq(got, nil, "to_minutes " .. vim.inspect(s) .. " value")
  eq(err, want, "to_minutes " .. vim.inspect(s) .. " error")
end

local function text(m, fmt, want, canonical)
  local got, err = D.from_minutes(m, fmt, canonical)
  eq(err, nil, "from_minutes " .. m .. " " .. vim.inspect(fmt) .. " error")
  eq(got, want, "from_minutes " .. m .. " " .. vim.inspect(fmt))
end

local function from_error(m, fmt, want)
  local got, err = D.from_minutes(m, fmt)
  eq(got, nil, "from_minutes " .. m .. " " .. vim.inspect(fmt) .. " value")
  eq(err, want, "from_minutes " .. m .. " " .. vim.inspect(fmt) .. " error")
end

-- p: units, mixed and H:MM forms; matching folds ASCII case.
for _, s in ipairs({ "1h", "1.5d 2:30", "01:30", " 1:30:00 ", "2H", "2MIN", "1h\t30min" }) do
  assert(D.p(s) == true, "p " .. vim.inspect(s))
end
for _, s in ipairs({ "", " ", "30", "1:30:5", "1min30", "3mins", "1h\r", "1m\u{130}n", 30, nil }) do
  assert(D.p(s) == false, "p " .. vim.inspect(s))
end

-- to_minutes: every branch, in Emacs's order.
minutes("", 0)
minutes(90, 90)
minutes("01:30", 90)
minutes("1:99:99", 160.65)
minutes(" 1:30 ", 90)
minutes("1h\t30min", 90)
minutes("1.h", 60)
minutes("1 h", 60)
minutes("1h 2h", 180)
minutes("2y 3m", 1181520)
minutes("1w2d", 12960)
minutes("1d 1:30:15", 1530.25)
minutes("1.5d 2:30", 2310)
minutes("1.", 1)
minutes("1.5", 1.5)
minutes("0", 0)

-- Unit lookup is case-sensitive, so a folded match still fails.
to_error("2H", 'Unknown unit: "H"')
to_error("1Min", 'Unknown unit: "Min"')
to_error(" 30", 'Invalid duration format: " 30"')
to_error("1min30", 'Invalid duration format: "1min30"')
to_error("1e3", 'Invalid duration format: "1e3"')
to_error('"1h"', 'Invalid duration format: "\\"1h\\""')
to_error("1h\\", 'Invalid duration format: "1h\\\\"')

-- Canonical units are min, h and d; the mixed form's units part ignores
-- the flag, as Emacs does.
minutes("1d", 1440, true)
to_error("1w", 'Unknown unit: "w"', true)
minutes("1w 1:00", 10140, true)

-- Range: every integer formed stays below 2^53.
minutes("9007199254740991", 9007199254740991)
to_error("9007199254740992", "duration out of range")
to_error("12345678901234567890", "duration out of range")
minutes("150119987579016h", 150119987579016 * 60)
to_error("150119987579017h", "duration out of range")
to_error("999999999999999:59:59", "duration out of range")
to_error("9007199254740991min 1min", "duration out of range")
to_error("99999999999999999999h 1H", "duration out of range")
to_error("1H 99999999999999999999h", 'Unknown unit: "H"')
minutes("9007199254740992.5h", 9007199254740992.5 * 60)

-- from_minutes: the symbol formats and the default.
text(90, "h:mm", "1:30")
text(90.25, "h:mm", "1:30")
text(90.25, "h:mm:ss", "1:30:15")
text(1441, nil, "1d 0:01")
text(1439, nil, "23:59")
text(-90, nil, "-1:30")
text(-0.5, "h:mm:ss", "-0:00:30")
text(1441, {}, "1d 0:01")

-- Unit lists, fractional and compact forms.
text(1500.5, { { "d" }, { "h" }, { "min" } }, "1d 1h")
text(90, { { "d" }, { "h", true }, { "min" } }, "1h 30min")
text(90.25, { { "h", true }, { special = 1 } }, "1.5h")
text(10080, { { "w", true }, { special = "h:mm" }, "compact" }, "1w0:00")
text(525960, { { "y" }, { "m" }, { "w" }, { "d" }, { "h" }, { "min" }, "compact" }, "1y")
text(100, { { "min" }, { "d" }, { "min", true } }, "100min 0min")
text(100, { "compact" }, "0")
text(0, { { "min" }, { special = 0 } }, "0min")
text(5e-324, { { "min" }, { special = 2 } }, "0.00min")
text(600000, { { "y" }, { special = "h:mm" } }, "1y 0:00")

-- Errors, with Emacs's messages.
from_error(100, { { special = 2 } }, "Unknown unit: nil")
from_error(100, { { "a" }, { "b" } }, 'Unknown unit: "b"')
from_error(100, { { "d" }, { "a" }, { "b" } }, 'Unknown unit: "a"')
from_error(100, { { "d" }, { special = -1 } }, "Unknown formatting directive: -1")
from_error(100, { { "d" }, { special = "foo" } }, "Unknown formatting directive: foo")
from_error(100, "foo", "Invalid duration format specification: foo")
local got, err = D.from_minutes(10080, { { "w" }, { special = 2 } }, true)
eq(got, nil, "canonical w")
eq(err, 'Unknown unit: "w"', "canonical w error")

-- Range: |minutes| * 60 < 2^53, compared exactly.
text(150119987579016.53125, "h:mm", "2501999792983:36")
from_error(150119987579016.5625, "h:mm", "duration out of range")
from_error(1000000000000001, "h:mm:ss", "duration out of range")
from_error(-1e18, nil, "duration out of range")
from_error(math.huge, nil, "duration out of range")
from_error(0 / 0, nil, "duration out of range")

-- h_mm_only_p.
eq(D.h_mm_only_p({}), "h:mm", "h_mm_only_p empty")
eq(D.h_mm_only_p({ "1:00", "foo" }), "h:mm", "h_mm_only_p H:MM")
eq(D.h_mm_only_p({ "1:00", "1:00:00" }), "h:mm:ss", "h_mm_only_p H:MM:SS")
eq(D.h_mm_only_p({ "1:00:00", "1h" }), nil, "h_mm_only_p units")
eq(D.h_mm_only_p({ "1d 1:00" }), nil, "h_mm_only_p mixed")

-- Arguments outside the contract raise.
assert(not pcall(D.to_minutes, {}), "to_minutes of a table raises")
assert(not pcall(D.from_minutes, "90"), "from_minutes of a string raises")
assert(not pcall(D.from_minutes, 90, { 42 }), "from_minutes of a bad entry raises")

io.write("duration ok\n")
os.exit(0)
