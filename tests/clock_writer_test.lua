-- Unit tests for clock.writer.
-- Run via: nvim --headless -l tests/clock_writer_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local writer = require("organ.clock.writer")

local function buf(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end

local function read(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- 1. write_active creates LOGBOOK if absent.
do
  local b = buf({ "* Heading", "  body line" })
  local start_ts = os.time({ year = 2026, month = 4, day = 26, hour = 14, min = 30, sec = 0 })
  writer.write_active(b, 1, "LOGBOOK", start_ts)
  local out = read(b)
  assert(out[2] == "  :LOGBOOK:", "got line 2: " .. tostring(out[2]))
  assert(
    out[3]:match("^  CLOCK: %[2026%-04%-26 [A-Z][a-z]+ 14:30%]$"),
    "got line 3: " .. tostring(out[3])
  )
  assert(out[4] == "  :END:", "got line 4: " .. tostring(out[4]))
  assert(out[5] == "  body line", "body should follow")
end

-- 2. write_active prepends inside an existing LOGBOOK.
do
  local b = buf({
    "* Heading",
    "  :LOGBOOK:",
    '  - State "DONE" from "TODO" [2026-04-25 Sat 10:00] \\\\',
    "  :END:",
    "  body",
  })
  local start_ts = os.time({ year = 2026, month = 4, day = 26, hour = 14, min = 30, sec = 0 })
  writer.write_active(b, 1, "LOGBOOK", start_ts)
  local out = read(b)
  assert(
    out[3]:match("^  CLOCK: %[2026%-04%-26 [A-Z][a-z]+ 14:30%]$"),
    "new CLOCK should be at line 3 (top of drawer); got " .. tostring(out[3])
  )
end

-- 3. close_active replaces the open CLOCK line with the closed form.
do
  local b = buf({
    "* Heading",
    "  :LOGBOOK:",
    "  CLOCK: [2026-04-26 Sun 14:30]",
    "  :END:",
  })
  local end_ts = os.time({ year = 2026, month = 4, day = 26, hour = 15, min = 45, sec = 0 })
  writer.close_active(b, 1, "LOGBOOK", end_ts)
  local out = read(b)
  assert(
    out[3]:match(
      "^  CLOCK: %[2026%-04%-26 [A-Z][a-z]+ 14:30%]%-%-%[2026%-04%-26 [A-Z][a-z]+ 15:45%]%s+=>%s+1:15$"
    ),
    "closed CLOCK line wrong: " .. tostring(out[3])
  )
end

-- 4. cancel_active removes the open CLOCK line; drawer kept.
do
  local b = buf({
    "* Heading",
    "  :LOGBOOK:",
    "  CLOCK: [2026-04-26 Sun 14:30]",
    "  :END:",
  })
  writer.cancel_active(b, 1, "LOGBOOK")
  local out = read(b)
  assert(out[2] == "  :LOGBOOK:", "drawer header preserved")
  assert(out[3] == "  :END:", "drawer end preserved; got " .. tostring(out[3]))
  assert(#out == 3, "expected 3 lines; got " .. #out)
end

-- 5. close_active with no open CLOCK line → returns false.
do
  local b = buf({
    "* Heading",
    "  :LOGBOOK:",
    '  - State "DONE" from "TODO" [2026-04-25 Sat 10:00] \\\\',
    "  :END:",
  })
  local end_ts = os.time()
  local ok = writer.close_active(b, 1, "LOGBOOK", end_ts)
  assert(ok == false, "close_active should return false on no match")
end

-- 6. Duration formatting: 6h 5m → "6:05"; 100h 30m → "100:30".
do
  local b = buf({
    "* H",
    "  :LOGBOOK:",
    "  CLOCK: [2026-04-26 Sun 00:00]",
    "  :END:",
  })
  local start_ts = os.time({ year = 2026, month = 4, day = 26, hour = 0, min = 0, sec = 0 })
  writer.close_active(b, 1, "LOGBOOK", start_ts + 6 * 3600 + 5 * 60)
  local out = read(b)
  assert(out[3]:match("=>%s+6:05$"), "got: " .. out[3])

  local b2 = buf({
    "* H",
    "  :LOGBOOK:",
    "  CLOCK: [2026-04-26 Sun 00:00]",
    "  :END:",
  })
  writer.close_active(b2, 1, "LOGBOOK", start_ts + 100 * 3600 + 30 * 60)
  local out2 = read(b2)
  assert(out2[3]:match("=>%s+100:30$"), "got: " .. out2[3])
end

-- The clock-out line is byte-for-byte Emacs's.  `org-clock-out` does
-- `(insert-and-inherit " => " (format "%2d:%02d" h m))` (org-clock.el), so
-- there is ONE space before `=>` and the hour is padded to two columns --
-- verified with `emacs --batch -Q`, whose output is
-- `CLOCK: [...]--[...] =>  0:00`.
do
  local b = buf({ "* H", "  :LOGBOOK:", "  CLOCK: [2026-04-26 Sun 00:00]", "  :END:" })
  local start_ts = os.time({ year = 2026, month = 4, day = 26, hour = 0, min = 0, sec = 0 })
  writer.close_active(b, 1, "LOGBOOK", start_ts + 90 * 60)
  local out = read(b)
  assert(
    out[3] == "  CLOCK: [2026-04-26 Sun 00:00]--[2026-04-26 Sun 01:30] =>  1:30",
    "single-digit hour: " .. ("%q"):format(out[3])
  )

  local b2 = buf({ "* H", "  :LOGBOOK:", "  CLOCK: [2026-04-26 Sun 00:00]", "  :END:" })
  writer.close_active(b2, 1, "LOGBOOK", start_ts + 25 * 3600)
  local out2 = read(b2)
  assert(
    out2[3] == "  CLOCK: [2026-04-26 Sun 00:00]--[2026-04-27 Mon 01:00] => 25:00",
    "two-digit hour must not gain a third space: " .. ("%q"):format(out2[3])
  )
end

-- The drawer indent follows the headline level, like every other drawer
-- writer -- a level-3 entry must not get planning at 4 and LOGBOOK at 2.
do
  local b = buf({ "* A", "** B", "*** H", "    SCHEDULED: <2026-04-26 Sun>", "    body" })
  local start_ts = os.time({ year = 2026, month = 4, day = 26, hour = 14, min = 30, sec = 0 })
  writer.write_active(b, 3, "LOGBOOK", start_ts)
  local out = read(b)
  assert(out[5] == "    :LOGBOOK:", "got line 5: " .. ("%q"):format(out[5]))
  assert(out[6]:match("^    CLOCK: %["), "got line 6: " .. ("%q"):format(out[6]))
  assert(out[7] == "    :END:", "got line 7: " .. ("%q"):format(out[7]))
end

io.write("clock writer ok\n")
os.exit(0)
