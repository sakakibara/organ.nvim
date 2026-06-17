-- format.adapt_indentation: real (on-disk) body indent that mirrors
-- Emacs's `org-adapt-indentation`.  Indent column is the section indent
-- (`todo.planning_indent`, default "adapt" = level+1 = Emacs `stars + 1`),
-- so it agrees with planning / drawer canonicalization and indentexpr.
-- Pins the matrix:
--   * disabled (default) -- file passes through unchanged
--   * "headline-data"    -- planning/drawer/property indented to level+1;
--                           body prose stays at column 0
--   * true               -- every body line indented to level+1
--   * src block bodies   -- NEVER reindented (verbatim contract)
--   * pre-first-headline -- never indented (no parent level)
--   * planning_indent    -- a fixed-number config is honored
--
-- Ground-truthed against GNU Emacs 30.1 / org 9.7.11 (org-adapt-indentation
-- t / headline-data both indent to stars+1).
--
-- Run via: nvim --headless -l tests/format_adapt_indentation_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local format = require("organ.format")

local INPUT = {
  "#+TITLE: Adapt indent demo",
  "",
  "* Top heading",
  "SCHEDULED: <2026-05-06 Wed>",
  ":PROPERTIES:",
  ":Effort:   1h",
  ":END:",
  "Body prose under top.",
  "** Child",
  "DEADLINE: <2026-05-08 Fri>",
  "More prose under child.",
  "",
  "#+begin_src lua",
  "  print('verbatim -- never reindented')",
  "#+end_src",
}

-- 1. disabled: pass-through.
do
  local out = format._apply_adapt_indentation(INPUT, false, "adapt")
  check("disabled: identical output", table.concat(out, "\n") == table.concat(INPUT, "\n"))
end

-- 2. "headline-data": planning + drawer + property indented to level+1;
--    prose stays at column 0.
do
  local out = format._apply_adapt_indentation(INPUT, "headline-data", "adapt")
  check(
    "headline-data: SCHEDULED -> level+1 (2)",
    out[4] == "  SCHEDULED: <2026-05-06 Wed>",
    out[4]
  )
  check("headline-data: PROPERTIES open -> 2", out[5] == "  :PROPERTIES:", out[5])
  check("headline-data: property line -> 2", out[6] == "  :Effort:   1h", out[6])
  check("headline-data: drawer close -> 2", out[7] == "  :END:", out[7])
  check("headline-data: body prose stays at col 0", out[8] == "Body prose under top.", out[8])
  check(
    "headline-data: child DEADLINE -> level+1 (3)",
    out[10] == "   DEADLINE: <2026-05-08 Fri>",
    out[10]
  )
  check("headline-data: child body stays at col 0", out[11] == "More prose under child.", out[11])
end

-- 3. true: every body line under a headline indents to level+1.
do
  local out = format._apply_adapt_indentation(INPUT, true, "adapt")
  check("true: SCHEDULED -> 2", out[4] == "  SCHEDULED: <2026-05-06 Wed>", out[4])
  check("true: body prose -> level+1 (2)", out[8] == "  Body prose under top.", out[8])
  check("true: child body -> level+1 (3)", out[11] == "   More prose under child.", out[11])
end

-- 4. Source block bodies stay verbatim under both modes.
do
  local out_h = format._apply_adapt_indentation(INPUT, "headline-data", "adapt")
  local out_t = format._apply_adapt_indentation(INPUT, true, "adapt")
  check(
    "src body unchanged (headline-data)",
    out_h[14] == "  print('verbatim -- never reindented')"
  )
  check("src body unchanged (true)", out_t[14] == "  print('verbatim -- never reindented')")
end

-- 5. Pre-first-headline content (the #+TITLE) never indents.
do
  local out = format._apply_adapt_indentation(INPUT, true, "adapt")
  check("pre-headline #+TITLE untouched", out[1] == "#+TITLE: Adapt indent demo")
end

-- 6. A fixed-number planning_indent is honored (all levels -> N spaces).
do
  local out = format._apply_adapt_indentation(INPUT, true, 4)
  check(
    "planning_indent=4: L1 SCHEDULED -> 4 spaces",
    out[4] == "    SCHEDULED: <2026-05-06 Wed>",
    out[4]
  )
  check(
    "planning_indent=4: L2 DEADLINE -> 4 spaces",
    out[10] == "    DEADLINE: <2026-05-08 Fri>",
    out[10]
  )
end

-- 7. End-to-end: format_lines threads the option through (default
--    planning_indent = "adapt" -> level+1).
do
  local prev = require("organ").config.indent
  require("organ").config.indent =
    vim.tbl_deep_extend("force", prev or {}, { adapt_indentation = "headline-data" })
  local out = format.format_lines(INPUT, {
    headline = { normalize_whitespace = true },
    blanks = { trim_trailing = false, ensure_final_newline = false },
  })
  require("organ").config.indent = prev
  check("format_lines: SCHEDULED -> 2", out[4] == "  SCHEDULED: <2026-05-06 Wed>", out[4])
  check("format_lines: src body untouched", out[14] == "  print('verbatim -- never reindented')")
end

-- 8. Empty drawer marker does NOT trip body-indent into the wrong state.
do
  local input = { "* H", ":PROPERTIES:", ":END:", "Prose." }
  local out = format._apply_adapt_indentation(input, "headline-data", "adapt")
  check("post-:END: prose stays at col 0", out[4] == "Prose.")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_adapt_indentation_test: PASS")
