-- TODO keyword annotation parser + log-policy + fast-selection.
-- Run via: nvim --headless -l tests/todo_annotations_test.lua

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
local parse = todo._parse_keyword

-- Annotation parser.
local p = parse("TODO")
check("bare: name=TODO", p.name == "TODO" and p.key == nil)

p = parse("TODO(t)")
check("key only: name=TODO key=t", p.name == "TODO" and p.key == "t")
check("key only: no log policy", p.on_enter == nil and p.on_exit == nil)

p = parse("NEXT(n!)")
check("key + on_enter time: NEXT(n!)", p.name == "NEXT" and p.key == "n" and p.on_enter == "time")

p = parse("WAIT(w@)")
check("key + on_enter note: WAIT(w@)", p.name == "WAIT" and p.key == "w" and p.on_enter == "note")

p = parse("DONE(d/!)")
check("key + on_exit time: DONE(d/!)", p.name == "DONE" and p.key == "d" and p.on_exit == "time")

p = parse("DONE(d@/!)")
check(
  "both enter+exit: DONE(d@/!)",
  p.name == "DONE" and p.key == "d" and p.on_enter == "note" and p.on_exit == "time"
)

p = parse("REPORT(@)")
check(
  "no key, on_enter only: REPORT(@)",
  p.name == "REPORT" and p.key == nil and p.on_enter == "note"
)

p = parse("DONE(@/!)")
check(
  "no key, both enter+exit: DONE(@/!)",
  p.name == "DONE" and p.key == nil and p.on_enter == "note" and p.on_exit == "time"
)

-- Log policy resolution.
local cfg = {
  sequence = { "TODO(t)", "WAIT(w@)", "|", "DONE(d!)" },
}
check(
  "policy: TODO -> WAIT picks up WAIT's @ (note)",
  todo._resolve_log_policy("TODO", "WAIT", cfg) == "note"
)
check(
  "policy: WAIT -> DONE picks up DONE's ! (time)",
  todo._resolve_log_policy("WAIT", "DONE", cfg) == "time"
)
check(
  "policy: TODO -> DONE picks up DONE's ! (time)",
  todo._resolve_log_policy("TODO", "DONE", cfg) == "time"
)
check("policy: TODO -> TODO is nil", todo._resolve_log_policy("TODO", "TODO", cfg) == nil)
check("policy: nil destination is nil", todo._resolve_log_policy("TODO", nil, cfg) == nil)

-- on_exit kicks in when destination has no on_enter annotation.
local cfg_exit = { sequence = { "TODO(t/!)", "DONE(d)" } }
check(
  "policy: on_exit fires when dest has no on_enter",
  todo._resolve_log_policy("TODO", "DONE", cfg_exit) == "time"
)

-- Explicit log_states overrides annotations.
local cfg_override = {
  sequence = { "TODO(t)", "DONE(d!)" },
  log_states = { DONE = false },
}
check(
  "policy: log_states[DONE]=false suppresses annotation",
  todo._resolve_log_policy("TODO", "DONE", cfg_override) == nil
)

-- Metadata map.
local meta = todo._build_metadata({ "TODO(t)", "WAIT(w@)", "|", "DONE(d!)" })
check("metadata: TODO key=t", meta.TODO and meta.TODO.key == "t")
check("metadata: WAIT on_enter=note", meta.WAIT and meta.WAIT.on_enter == "note")
check("metadata: DONE on_enter=time", meta.DONE and meta.DONE.on_enter == "time")
check("metadata: pipe excluded", meta["|"] == nil)

-- Multi-sequence metadata.
local meta_multi = todo._build_metadata({
  { "TODO(t)", "|", "DONE(d!)" },
  { "BUG(b)", "|", "FIXED(f@)" },
})
check("multi-seq metadata: TODO + BUG both indexed", meta_multi.TODO and meta_multi.BUG)
check("multi-seq metadata: FIXED on_enter=note", meta_multi.FIXED.on_enter == "note")

-- Cycling still works with annotated config (annotations don't break it).
check(
  "cycling with annotations: TODO -> WAIT",
  todo._compute_next_state("TODO", { "TODO(t)", "WAIT(w@)", "|", "DONE(d!)" }) == "WAIT"
)
check(
  "cycling with annotations: WAIT -> DONE",
  todo._compute_next_state("WAIT", { "TODO(t)", "WAIT(w@)", "|", "DONE(d!)" }) == "DONE"
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("todo_annotations_test: PASS")
