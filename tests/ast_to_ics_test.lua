-- Unit tests for organ.ast.to_ics.
-- Run via: nvim --headless -l tests/ast_to_ics_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local A = require("organ.ast")
local to_ics = require("organ.ast.to_ics")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- _parse_org_ts
do
  local p = to_ics._parse_org_ts("<2026-05-02 Sat>")
  check("parse all-day date", p and p.all_day and p.date == "20260502", "got: " .. vim.inspect(p))

  p = to_ics._parse_org_ts("<2026-05-02 Sat 14:30>")
  check(
    "parse timed start only",
    p and p.start_time == "143000" and not p.end_time,
    "got: " .. vim.inspect(p)
  )

  p = to_ics._parse_org_ts("<2026-05-02 Sat 14:30-15:00>")
  check(
    "parse time range",
    p and p.start_time == "143000" and p.end_time == "150000",
    "got: " .. vim.inspect(p)
  )

  p = to_ics._parse_org_ts("[2026-05-01 Fri 12:00]")
  check(
    "parse inactive bracket form",
    p and p.date == "20260501" and p.start_time == "120000",
    "got: " .. vim.inspect(p)
  )
end

-- _fold_line
do
  local short = to_ics._fold_line("SHORT")
  check("short line untouched", short == "SHORT", "got: " .. short)

  local long = to_ics._fold_line(string.rep("X", 200))
  check(
    "long line folds with CRLF + space",
    long:find("\r\n ", 1, true) ~= nil,
    "got: " .. long:sub(1, 100)
  )
end

-- Empty / nil ast
do
  local out = to_ics.render(A.document({}))
  check("empty doc has VCALENDAR begin", out:find("BEGIN:VCALENDAR", 1, true) ~= nil)
  check("empty doc has VCALENDAR end", out:find("END:VCALENDAR", 1, true) ~= nil)
  check("empty doc has VERSION:2.0", out:find("VERSION:2.0", 1, true) ~= nil)
  check("empty doc has PRODID", out:find("PRODID:", 1, true) ~= nil)
  local n = 0
  for _ in out:gmatch("BEGIN:VEVENT") do
    n = n + 1
  end
  check("empty doc produces no VEVENT", n == 0, "got " .. n)
end

-- Two planned headlines
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = { A.text("Standup") },
      planning = { scheduled = "<2026-05-04 Mon 09:00-09:15>" },
      properties = { ID = "standup-uuid" },
    }),
    A.headline({
      level = 1,
      title = { A.text("Project") },
      planning = { deadline = "<2026-05-15 Fri>" },
    }),
  })
  local out = to_ics.render(doc)

  local n = 0
  for _ in out:gmatch("BEGIN:VEVENT") do
    n = n + 1
  end
  check("two VEVENTs from two planned headlines", n == 2, "got " .. n .. "; out:\n" .. out)

  check(
    "SCHEDULED timed DTSTART",
    out:find("DTSTART:20260504T090000", 1, true) ~= nil,
    "out:\n" .. out
  )
  check(
    "SCHEDULED time range DTEND",
    out:find("DTEND:20260504T091500", 1, true) ~= nil,
    "out:\n" .. out
  )
  check("UID from properties.ID", out:find("UID:standup-uuid", 1, true) ~= nil, "out:\n" .. out)
  check("Standup SUMMARY plain", out:find("SUMMARY:Standup", 1, true) ~= nil, "out:\n" .. out)

  check(
    "DEADLINE all-day DTSTART;VALUE=DATE",
    out:find("DTSTART;VALUE=DATE:20260515", 1, true) ~= nil,
    "out:\n" .. out
  )
  check(
    "DEADLINE summary prefix",
    out:find("SUMMARY:(Deadline) Project", 1, true) ~= nil,
    "out:\n" .. out
  )
  check(
    "synthesized UID for headline without :ID:",
    out:find("UID:organ-2-deadline", 1, true) ~= nil,
    "out:\n" .. out
  )
end

-- Headlines without planning are skipped
do
  local doc = A.document({
    A.headline({ level = 1, title = { A.text("Plain") } }),
    A.headline({
      level = 1,
      title = { A.text("Note only") },
      properties = { ID = "x" },
    }),
  })
  local out = to_ics.render(doc)
  local n = 0
  for _ in out:gmatch("BEGIN:VEVENT") do
    n = n + 1
  end
  check("no VEVENT without planning", n == 0, "got " .. n)
end

-- Nested headlines walked correctly
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = { A.text("Parent") },
      children = {
        A.headline({
          level = 2,
          title = { A.text("Child") },
          planning = { scheduled = "<2026-05-04 Mon>" },
          children = {
            A.headline({
              level = 3,
              title = { A.text("Grand") },
              planning = { deadline = "<2026-05-10 Sun>" },
            }),
          },
        }),
      },
    }),
  })
  local out = to_ics.render(doc)
  local n = 0
  for _ in out:gmatch("BEGIN:VEVENT") do
    n = n + 1
  end
  check("nested headlines produce VEVENTs", n == 2, "got " .. n .. "; out:\n" .. out)
  check(
    "deep child SCHEDULED present",
    out:find("DTSTART;VALUE=DATE:20260504", 1, true) ~= nil,
    "out:\n" .. out
  )
  check(
    "deeper grandchild DEADLINE present",
    out:find("SUMMARY:(Deadline) Grand", 1, true) ~= nil,
    "out:\n" .. out
  )
end

-- Emphasis stripped from summary
do
  local doc = A.document({
    A.headline({
      level = 1,
      title = {
        A.text("Hello "),
        A.emphasis("bold", { A.text("world") }),
      },
      planning = { scheduled = "<2026-05-04 Mon>" },
    }),
  })
  local out = to_ics.render(doc)
  check(
    "emphasis flattened to plain text in SUMMARY",
    out:find("SUMMARY:Hello world", 1, true) ~= nil,
    "out:\n" .. out
  )
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("ast_to_ics_test: PASS")
os.exit(0)
