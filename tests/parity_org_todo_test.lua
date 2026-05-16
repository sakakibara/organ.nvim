-- Emacs parity: org-todo cycle semantics.
--
-- Verifies that `organ.todo.cycle` produces the same headline state
-- transitions as Emacs `org-todo' for several cases that are easy to
-- get wrong when porting:
--
--   * cycle from no-state -> first keyword
--   * cycle between active keywords (TODO -> NEXT -> WAIT -> ...)
--   * cycle from last keyword (after DONE) -> back to no-state
--   * cycle backward (org-shiftleft) -> previous state
--
-- Cursor is placed via the `<CURSOR>` marker so both sides agree on
-- which headline the op targets.  Result is the FULL buffer content.
--
-- Run via: nvim --headless -l tests/parity_org_todo_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parity = dofile(root .. "/tests/_emacs_parity.lua")
parity.skip_if_no_emacs()

-- Null out logging so the parity check isolates CYCLE SEMANTICS from
-- LOGGING POLICY.  Our default (`log_done = "time"`) inserts a CLOSED
-- timestamp on TODO -> DONE; Emacs's default is no auto-log.  Both
-- behaviors are valid; the cycle algorithm is what we want to compare.
require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = {
    log_done = false,
    log_state_changes = false,
    log_reschedule = false,
    log_redeadline = false,
    log_refile = false,
  },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local function our_op(op, input)
  -- Spin up a transient buffer with the input + cursor, run our op,
  -- return the full buffer content as a string.
  local stripped, cursor = parity.parse_cursor(input)
  local b = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(stripped, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_win_set_cursor(0, cursor)
  local todo = require("organ.todo")
  if op == "org-todo" or op == "org-shiftright" then
    todo.cycle(b, cursor[1])
  elseif op == "org-shiftleft" then
    todo.cycle_back(b, cursor[1])
  else
    error("unsupported op: " .. op)
  end
  local out_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  vim.api.nvim_buf_delete(b, { force = true })
  return table.concat(out_lines, "\n") .. "\n"
end

-- Use Emacs's default sequence so both sides agree without needing
-- to round-trip a `#+TODO:` directive.  Emacs default: TODO | DONE.
-- Our default differs (TODO NEXT WAITING HOLD PROJ | DONE CANCELLED),
-- so we put a `#+TODO:` directive in each fixture to align.

local function with_sequence(seq, body)
  return ("#+TODO: %s\n%s"):format(seq, body)
end

local cases = {
  {
    label = "cycle from no-state -> TODO (single sequence)",
    op = "org-todo",
    input = with_sequence("TODO | DONE", "* <CURSOR>Heading\n"),
  },
  {
    label = "cycle TODO -> DONE (single sequence)",
    op = "org-todo",
    input = with_sequence("TODO | DONE", "* TODO <CURSOR>Heading\n"),
  },
  {
    label = "cycle DONE -> no-state (single sequence)",
    op = "org-todo",
    input = with_sequence("TODO | DONE", "* DONE <CURSOR>Heading\n"),
  },
  {
    label = "cycle TODO -> NEXT (three-active sequence)",
    op = "org-todo",
    input = with_sequence("TODO NEXT WAIT | DONE", "* TODO <CURSOR>Heading\n"),
  },
  {
    label = "cycle WAIT -> DONE (three-active sequence; jumps active->done)",
    op = "org-todo",
    input = with_sequence("TODO NEXT WAIT | DONE", "* WAIT <CURSOR>Heading\n"),
  },
  {
    label = "shiftleft from NEXT -> TODO (backward cycle)",
    op = "org-shiftleft",
    input = with_sequence("TODO NEXT WAIT | DONE", "* NEXT <CURSOR>Heading\n"),
  },
  {
    label = "shiftleft from TODO -> no-state (wrap back off the front)",
    op = "org-shiftleft",
    input = with_sequence("TODO NEXT WAIT | DONE", "* TODO <CURSOR>Heading\n"),
  },
}

for _, c in ipairs(cases) do
  local emacs_out = parity.run(c.op, c.input)
  local our_out = our_op(c.op, c.input)
  check(c.label, emacs_out == our_out, string.format("emacs=%q\n     ours= %q", emacs_out, our_out))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("parity_org_todo_test: PASS")
