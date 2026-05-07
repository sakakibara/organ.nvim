-- Format: empty-line policy + drawer value alignment.
--
-- Run via: nvim --headless -l tests/format_blanks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fmt = require("organ.format")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Drawer value alignment: keys padded to longest key + min indent.
do
  local input = {
    "* H1",
    ":PROPERTIES:",
    ":ID: 1",
    ":CATEGORY: cat",
    ":LONG_KEY_NAME: value",
    ":END:",
  }
  local out = fmt.format_lines(input, {
    drawers = { align_values = true, min_value_indent = 1 },
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
    blanks = { trim_trailing = false, ensure_final_newline = false },
    trim_trailing_whitespace = false,
  })
  check("drawer: :ID: padded", out[3] == ":ID:            1", "got " .. tostring(out[3]))
  check("drawer: :CATEGORY: padded", out[4] == ":CATEGORY:      cat", "got " .. tostring(out[4]))
  check(
    "drawer: :LONG_KEY_NAME: only min-indent (it's the longest)",
    out[5] == ":LONG_KEY_NAME: value",
    "got " .. tostring(out[5])
  )
  check("drawer: :END: passes through", out[6] == ":END:")
end

-- Drawer alignment off: leave verbatim.
do
  local input = { "* H1", ":PROPERTIES:", ":ID:    1", ":CATEGORY:  cat", ":END:" }
  local out = fmt.format_lines(input, {
    drawers = { align_values = false },
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
    blanks = { trim_trailing = false, ensure_final_newline = false },
    trim_trailing_whitespace = false,
  })
  check("drawer align_values=false: row 3 untouched", out[3] == ":ID:    1")
  check("drawer align_values=false: row 4 untouched", out[4] == ":CATEGORY:  cat")
end

-- LOGBOOK lines (not `:KEY: value`) pass through.
do
  local input = {
    ":LOGBOOK:",
    '- State "DONE" from "TODO" [2026-01-01]',
    "- some other note",
    ":END:",
  }
  local out = fmt.format_lines(input, {
    drawers = { align_values = true },
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
    blanks = { trim_trailing = false, ensure_final_newline = false },
    trim_trailing_whitespace = false,
  })
  check("LOGBOOK: list line untouched", out[2] == '- State "DONE" from "TODO" [2026-01-01]')
  check("LOGBOOK: second list line untouched", out[3] == "- some other note")
end

-- collapse_runs caps consecutive blanks.
do
  local input = { "line a", "", "", "", "", "line b" }
  local out = fmt.format_lines(input, {
    blanks = { collapse_runs = 2, trim_trailing = false, ensure_final_newline = false },
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
    trim_trailing_whitespace = false,
  })
  check(
    "collapse_runs=2: 4 blanks collapsed to 2",
    #out == 4 and out[2] == "" and out[3] == "" and out[4] == "line b"
  )
end

-- before_headline = 1: ensure exactly 1 blank before each heading.
do
  local input = { "para a", "* H1", "* H2", "body", "", "", "* H3" }
  local out = fmt.format_lines(input, {
    blanks = { before_headline = 1, trim_trailing = false, ensure_final_newline = false },
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
    trim_trailing_whitespace = false,
  })
  -- Expect: para a / "" / * H1 / "" / * H2 / body / "" / * H3
  check(
    "before_headline=1: blank inserted before H1",
    out[1] == "para a" and out[2] == "" and out[3] == "* H1"
  )
  check("before_headline=1: blank inserted between H1 and H2", out[4] == "" and out[5] == "* H2")
  check(
    "before_headline=1: 2 blanks collapsed to 1 before H3",
    out[6] == "body" and out[7] == "" and out[8] == "* H3"
  )
end

-- before_headline = 0: strip blanks before headings (Emacs's `nil` policy).
do
  local input = { "para", "", "", "* H1" }
  local out = fmt.format_lines(input, {
    blanks = { before_headline = 0, trim_trailing = false, ensure_final_newline = false },
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
    trim_trailing_whitespace = false,
  })
  check("before_headline=0: blanks stripped", #out == 2 and out[1] == "para" and out[2] == "* H1")
end

-- trim_trailing_whitespace: per-line trailing spaces stripped.
do
  local input = { "line a   ", "line b\t\t", "" }
  local out = fmt.format_lines(input, {
    trim_trailing_whitespace = true,
    blanks = { trim_trailing = false, ensure_final_newline = false },
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
  })
  check("trim_trailing_whitespace: line a", out[1] == "line a")
  check("trim_trailing_whitespace: line b", out[2] == "line b")
end

-- trim_eof: trailing blanks dropped.
do
  local input = { "line a", "line b", "", "", "" }
  local out = fmt.format_lines(input, {
    blanks = { trim_trailing = true, ensure_final_newline = false },
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
    trim_trailing_whitespace = false,
  })
  check("trim_eof: trailing blanks removed", #out == 2)
end

-- wrap.enabled = false: prose passes through verbatim.
do
  local input =
    { "* H1", "this is a single very long line that would have been wrapped if wrap was enabled" }
  local out = fmt.format_lines(input, {
    wrap = { enabled = false },
    headline = { normalize_whitespace = false },
    blanks = { trim_trailing = false, ensure_final_newline = false },
    trim_trailing_whitespace = false,
  })
  check(
    "wrap disabled: long line preserved",
    out[2] == "this is a single very long line that would have been wrapped if wrap was enabled"
  )
end

-- wrap.width = 30: wraps at 30 chars regardless of textwidth.
do
  local input = { "* H1", "one two three four five six seven eight nine ten" }
  local out = fmt.format_lines(input, {
    wrap = { enabled = true, width = 30 },
    headline = { normalize_whitespace = false },
    blanks = { trim_trailing = false, ensure_final_newline = false },
    trim_trailing_whitespace = false,
  })
  for i = 2, #out do
    check(
      "wrap.width=30: line " .. i .. " ≤ 30 chars",
      #out[i] <= 30,
      "got " .. #out[i] .. ": " .. out[i]
    )
  end
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_blanks_test: PASS")
os.exit(0)
