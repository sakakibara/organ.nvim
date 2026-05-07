-- format.adapt_indentation: real (on-disk) body indent that mirrors
-- Emacs's `org-adapt-indentation`.  Pins the matrix:
--   * disabled (default) -- file passes through unchanged
--   * "headline-data"    -- planning/drawer/property indented;
--                           body prose stays at column 0
--   * true               -- every body line indented
--   * src block bodies   -- NEVER reindented (verbatim contract)
--   * pre-first-headline -- never indented (no parent level)
--   * shift_per_level    -- honors custom values
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

-- ---------------------------------------------------------------------------
-- 1. disabled: pass-through.
-- ---------------------------------------------------------------------------
do
  local out = format._apply_adapt_indentation(INPUT, false, 2)
  check("disabled: identical output", table.concat(out, "\n") == table.concat(INPUT, "\n"))
end

-- ---------------------------------------------------------------------------
-- 2. "headline-data": planning + drawer + property indented;
--    prose stays at column 0.
-- ---------------------------------------------------------------------------
do
  local out = format._apply_adapt_indentation(INPUT, "headline-data", 2)
  -- Top-level (level 1) -> 1 space (= (1-1)*2 + 1 = 1).
  check("headline-data: SCHEDULED indented to 1 space", out[4] == " SCHEDULED: <2026-05-06 Wed>")
  check("headline-data: PROPERTIES drawer open indented", out[5] == " :PROPERTIES:")
  check("headline-data: property line indented", out[6] == " :Effort:   1h")
  check("headline-data: drawer close indented", out[7] == " :END:")
  check("headline-data: body prose stays at col 0", out[8] == "Body prose under top.")
  -- Level 2 -> 3 spaces (= (2-1)*2 + 1 = 3).
  check(
    "headline-data: child DEADLINE indented to 3 spaces",
    out[10] == "   DEADLINE: <2026-05-08 Fri>"
  )
  check("headline-data: child body prose stays at col 0", out[11] == "More prose under child.")
end

-- ---------------------------------------------------------------------------
-- 3. true: every body line under a headline indents (planning,
--    drawer, prose, etc.).
-- ---------------------------------------------------------------------------
do
  local out = format._apply_adapt_indentation(INPUT, true, 2)
  check("true: SCHEDULED indented", out[4] == " SCHEDULED: <2026-05-06 Wed>")
  check("true: body prose indented to 1 space (level 1)", out[8] == " Body prose under top.")
  check("true: child body indented to 3 spaces (level 2)", out[11] == "   More prose under child.")
end

-- ---------------------------------------------------------------------------
-- 4. Source block bodies stay verbatim under both modes.
-- ---------------------------------------------------------------------------
do
  local out_h = format._apply_adapt_indentation(INPUT, "headline-data", 2)
  local out_t = format._apply_adapt_indentation(INPUT, true, 2)
  check(
    "src body unchanged (headline-data)",
    out_h[14] == "  print('verbatim -- never reindented')"
  )
  check("src body unchanged (true)", out_t[14] == "  print('verbatim -- never reindented')")
end

-- ---------------------------------------------------------------------------
-- 5. Pre-first-headline content (the #+TITLE) never indents.
-- ---------------------------------------------------------------------------
do
  local out = format._apply_adapt_indentation(INPUT, true, 2)
  check("pre-headline #+TITLE untouched", out[1] == "#+TITLE: Adapt indent demo")
end

-- ---------------------------------------------------------------------------
-- 6. shift_per_level honored: shift=4 doubles the indent.
-- ---------------------------------------------------------------------------
do
  local out = format._apply_adapt_indentation(INPUT, true, 4)
  -- Level 1 -> (1-1)*4 + 1 = 1 space.
  check("shift=4: level 1 still 1 space", out[4] == " SCHEDULED: <2026-05-06 Wed>")
  -- Level 2 -> (2-1)*4 + 1 = 5 spaces.
  check("shift=4: level 2 = 5 spaces", out[10] == "     DEADLINE: <2026-05-08 Fri>")
end

-- ---------------------------------------------------------------------------
-- 7. End-to-end: format_lines threads the option through.
-- ---------------------------------------------------------------------------
do
  -- adapt_indentation lives in `indent.*` config; format_lines reads
  -- the live organ.config.indent inside its body, so set it via setup
  -- before calling.
  local prev = require("organ").config.indent
  require("organ").config.indent = vim.tbl_deep_extend("force", prev or {}, {
    adapt_indentation = "headline-data",
    shift_per_level = 2,
  })
  local out = format.format_lines(INPUT, {
    headline = { normalize_whitespace = true },
    blanks = { trim_trailing = false, ensure_final_newline = false },
  })
  require("organ").config.indent = prev
  check("format_lines: SCHEDULED indented", out[4] == " SCHEDULED: <2026-05-06 Wed>")
  check("format_lines: src body untouched", out[14] == "  print('verbatim -- never reindented')")
end

-- ---------------------------------------------------------------------------
-- 8. Empty drawer marker does NOT trip body-indent into the wrong
--    state (regression: was leaking in_drawer past :END:).
-- ---------------------------------------------------------------------------
do
  local input = {
    "* H",
    ":PROPERTIES:",
    ":END:",
    "Prose.",
  }
  local out = format._apply_adapt_indentation(input, "headline-data", 2)
  check("post-:END: prose stays at col 0", out[4] == "Prose.")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_adapt_indentation_test: PASS")
