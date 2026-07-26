-- Multi-sequence org-todo-keywords parity with Emacs.
-- Run via: nvim --headless -l tests/todo_multisequence_test.lua

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

local todo = require("organ.todo")

-- Annotation stripping: `"TODO(t!)"` → `"TODO"`.
local seqs = todo._normalise_sequences({ "TODO(t)", "WAIT(w@)", "|", "DONE(d!)" })
check("annotation stripped: TODO(t) -> TODO", seqs[1][1] == "TODO")
check("annotation stripped: WAIT(w@) -> WAIT", seqs[1][2] == "WAIT")
check("annotation stripped: DONE(d!) -> DONE", seqs[1][4] == "DONE")
check("pipe preserved", seqs[1][3] == "|")

-- Single-sequence input wraps as { { ... } }.
local single = todo._normalise_sequences({ "TODO", "|", "DONE" })
check("single sequence wrapped", #single == 1 and single[1][1] == "TODO")

-- Multi-sequence input passed through.
local multi = todo._normalise_sequences({
  { "TODO", "|", "DONE" },
  { "BUG", "TRIAGE", "|", "FIXED", "WONTFIX" },
})
check("multi: two sequences", #multi == 2)
check("multi: seq 1 = TODO/DONE", multi[1][1] == "TODO" and multi[1][3] == "DONE")
check("multi: seq 2 = BUG/FIXED", multi[2][1] == "BUG" and multi[2][4] == "FIXED")

-- Cycling within sequence 1 stays in sequence 1.
local m = { { "TODO", "WAIT", "|", "DONE" }, { "BUG", "|", "FIXED" } }
check("seq 1: TODO -> WAIT", todo._compute_next_state("TODO", m) == "WAIT")
check("seq 1: WAIT -> DONE", todo._compute_next_state("WAIT", m) == "DONE")
check("seq 1: DONE -> nil (off the end)", todo._compute_next_state("DONE", m) == nil)

-- Cycling within sequence 2 stays in sequence 2 (NOT crossing into seq 1).
check("seq 2: BUG -> FIXED", todo._compute_next_state("BUG", m) == "FIXED")
check("seq 2: FIXED -> nil", todo._compute_next_state("FIXED", m) == nil)

-- Backwards cycling within the matched sequence.
check("seq 1: WAIT -> TODO (back)", todo._compute_prev_state("WAIT", m) == "TODO")
check("seq 1: DONE -> WAIT (back)", todo._compute_prev_state("DONE", m) == "WAIT")
check("seq 2: FIXED -> BUG (back)", todo._compute_prev_state("FIXED", m) == "BUG")

-- nil -> first sequence's first state.
check("nil -> first state of seq 1", todo._compute_next_state(nil, m) == "TODO")

-- find_sequence helper.
local seq_for_bug = todo._find_sequence("BUG", multi)
check("find: BUG resolves to seq 2", seq_for_bug == multi[2])
local seq_for_done = todo._find_sequence("DONE", multi)
check("find: DONE resolves to seq 1", seq_for_done == multi[1])
local seq_for_unknown = todo._find_sequence("UNKNOWN", multi)
check("find: UNKNOWN -> nil", seq_for_unknown == nil)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("todo_multisequence_test: PASS")
