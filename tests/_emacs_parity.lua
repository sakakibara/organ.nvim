-- Helper for Emacs-parity tests.  Each test follows this shape:
--
--   local parity = dofile(root .. "/tests/_emacs_parity.lua")
--   parity.skip_if_no_emacs()
--   local emacs_out = parity.run("org-todo", input)
--   local our_out = our_impl(input)
--   parity.assert_equal("cycle TODO -> NEXT", emacs_out, our_out)
--
-- `run` writes `input` to a tempfile, invokes the generic op runner
-- (`scripts/emacs-op.el`) via `emacs --batch -Q`, and returns Emacs's
-- stdout verbatim.  See that file's header for the supported op list
-- and how to add new ones.

local M = {}

local root = vim.fn.getcwd()
local script = root .. "/scripts/emacs-op.el"

function M.available()
  return vim.fn.executable("emacs") == 1
end

function M.skip_if_no_emacs()
  if not M.available() then
    io.write("SKIP: emacs not installed\n")
    os.exit(0)
  end
  if vim.fn.filereadable(script) == 0 then
    io.write("SKIP: scripts/emacs-op.el not found\n")
    os.exit(0)
  end
end

-- Run an op through Emacs.  `input` is the buffer content; an optional
-- "<CURSOR>" marker inside places point for cursor-dependent ops.
-- Returns Emacs's stdout (the resulting buffer contents).
function M.run(op, input)
  local tmp = vim.fn.tempname()
  local f = assert(io.open(tmp, "w"))
  f:write(input)
  f:close()
  local cmd = string.format(
    "emacs --batch -Q -l %s --eval %s 2>/dev/null",
    vim.fn.shellescape(script),
    vim.fn.shellescape(string.format('(organ-op-run "%s" "%s")', op, tmp))
  )
  local out = vim.fn.system(cmd)
  vim.fn.delete(tmp)
  if vim.v.shell_error ~= 0 then
    error(string.format("emacs-op %q failed (exit %d):\n%s", op, vim.v.shell_error, out))
  end
  return out
end

-- Strip our cursor marker out of `input` and return the position (1-
-- indexed line, 0-indexed col) it referenced.  Defaults to {1, 0} if
-- no marker.  Same marker `<CURSOR>` as the .el side so both sides
-- agree on cursor placement.
function M.parse_cursor(input)
  local marker = "<CURSOR>"
  local pos = input:find(marker, 1, true)
  if not pos then
    return input, { 1, 0 }
  end
  local before = input:sub(1, pos - 1)
  local after = input:sub(pos + #marker)
  -- Count newlines in `before` to get the row (1-indexed).
  local row = 1
  for _ in before:gmatch("\n") do
    row = row + 1
  end
  -- Column = chars from last newline (or start) to marker, 0-indexed.
  local last_nl = before:find("\n[^\n]*$") or 0
  local col = #before - last_nl
  if last_nl > 0 then
    col = col - 1
  end
  return before .. after, { row, col }
end

return M
