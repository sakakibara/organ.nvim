-- Pure unit on todo._compute_next_state(current, sequence).
-- Run via: nvim --headless -l tests/todo_state_machine_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local todo = require("organ.todo")
local seq = { "TODO", "NEXT", "WAITING", "HOLD", "PROJ", "|", "DONE", "CANCELLED" }

local function eq(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

-- no-state → first active
eq(todo._compute_next_state(nil, seq), "TODO", "nil → TODO")

-- active → next active
eq(todo._compute_next_state("TODO", seq), "NEXT", "TODO → NEXT")
eq(todo._compute_next_state("NEXT", seq), "WAITING", "NEXT → WAITING")
eq(todo._compute_next_state("WAITING", seq), "HOLD", "WAITING → HOLD")
eq(todo._compute_next_state("HOLD", seq), "PROJ", "HOLD → PROJ")

-- last active before | → first done
eq(todo._compute_next_state("PROJ", seq), "DONE", "PROJ → DONE")

-- done → next done
eq(todo._compute_next_state("DONE", seq), "CANCELLED", "DONE → CANCELLED")

-- last done → nil
eq(todo._compute_next_state("CANCELLED", seq), nil, "CANCELLED → nil")

-- unknown → first active (recovery)
eq(todo._compute_next_state("UNKNOWN", seq), "TODO", "UNKNOWN → TODO")

-- no-`|` sequence: linear cycle, wraps to nil
local seq2 = { "TODO", "DONE" }
eq(todo._compute_next_state(nil, seq2), "TODO", "no-| nil → TODO")
eq(todo._compute_next_state("TODO", seq2), "DONE", "no-| TODO → DONE")
eq(todo._compute_next_state("DONE", seq2), nil, "no-| DONE → nil")

-- `|` at start (no actives, only dones)
local seq3 = { "|", "DONE", "ARCHIVED" }
eq(todo._compute_next_state(nil, seq3), "DONE", "|-first nil → DONE")
eq(todo._compute_next_state("DONE", seq3), "ARCHIVED", "|-first DONE → ARCHIVED")
eq(todo._compute_next_state("ARCHIVED", seq3), nil, "|-first last → nil")

io.write("todo state machine ok\n")
os.exit(0)
