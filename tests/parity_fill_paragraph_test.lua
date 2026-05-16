-- Emacs parity: paragraph reflow (fill-paragraph).
--
-- Verifies that `organ.format.format_lines` with wrap enabled produces
-- byte-identical output to GNU Emacs `org-mode` + `fill-paragraph` for
-- the cases below.  Ground truth is Emacs; if a case diverges, we
-- fix our implementation (do NOT update the expected output unless
-- you've confirmed the divergence is intentional and Emacs is wrong
-- for our use case -- rare).
--
-- Run via: nvim --headless -l tests/parity_fill_paragraph_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parity = dofile(root .. "/tests/_emacs_parity.lua")
parity.skip_if_no_emacs()

local fmt = require("organ.format")
local fails = 0

local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- `width` matches Emacs's default `fill-column` (70).  Override per case
-- when the case explicitly probes wrap-at-N behavior.
local function our_fill(input, width)
  local lines = vim.split(input, "\n", { plain = true })
  -- Drop the empty trailing entry if `input` ends with "\n".
  if lines[#lines] == "" then
    table.remove(lines)
  end
  local out = fmt.format_lines(lines, { wrap = { width = width or 70 } })
  return table.concat(out, "\n") .. "\n"
end

-- Each case: { label, input, [width] }.
-- Emacs's fill-paragraph appends a trailing newline; our reassembly
-- does the same so the strings compare byte-for-byte.
local cases = {
  {
    label = "A: plain consecutive lines reflow into one paragraph",
    input = "first line\nsecond line\n",
  },
  {
    label = "B: `\\\\` at EOL preserves the line break",
    input = "first line \\\\\nsecond line\n",
  },
  {
    label = "C: lines after a `\\\\` break still reflow among themselves",
    input = "first \\\\\nsecond\nthird\n",
  },
  {
    label = "D: trailing spaces (markdown convention) have no meaning",
    input = "first line  \nsecond line\n",
  },
  {
    label = "E: paragraph wider than fill-column wraps at width",
    input = "one two three four five six seven eight nine ten eleven twelve\n",
    width = 30,
  },
  {
    label = "F: blank line separates paragraphs (no cross-reflow)",
    input = "first paragraph one\nfirst paragraph two\n\nsecond paragraph\n",
  },
}

for _, c in ipairs(cases) do
  -- Pinning fill-column on the Emacs side: emacs-op.el doesn't currently
  -- override it, so Emacs uses its default (70).  For case E we need a
  -- narrower column, so we ask Emacs to use 30 via a one-shot setq.
  local emacs_in = c.input
  if c.width and c.width ~= 70 then
    -- Skip the case; emacs-op.el doesn't accept a width param yet.
    -- TODO: extend the .el side to accept `(:fill-column N)` etc.
    print("SKIP  " .. c.label .. " (custom width not yet wired through emacs-op.el)")
  else
    local emacs_out = parity.run("fill-paragraph", emacs_in)
    local our_out = our_fill(emacs_in, c.width or 70)
    check(
      c.label,
      emacs_out == our_out,
      string.format("emacs=%q\n     ours= %q", emacs_out, our_out)
    )
  end
end

-- Width-driven wrap is exercised via our own format_test.lua (case E
-- there).  Once emacs-op.el accepts a fill-column override, we'll move
-- that to a parity assertion.

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_fill_paragraph_test: PASS")
