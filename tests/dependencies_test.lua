-- TODO dependency guards: ORDERED, parent-blocked-by-children, checkboxes.
-- Run via: nvim --headless -l tests/dependencies_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local deps = require("organ.dependencies")

local SEQ = { "TODO", "DOING", "|", "DONE" }

-- Headline traversal helpers

do
  local lines = {
    "* TODO Project",
    "** TODO First child",
    "*** TODO Grandchild",
    "** DONE Second child",
    "* TODO Sibling project",
    "** TODO Sibling child",
  }
  -- Parent of a top-level: nil.
  assert(deps.parent_of(lines, 1) == nil, "no parent for top")
  -- Parent of "First child" (line 2) is "Project" (line 1).
  assert(deps.parent_of(lines, 2) == 1, "parent of first child")
  -- Parent of "Grandchild" (line 3) is "First child" (line 2).
  assert(deps.parent_of(lines, 3) == 2, "parent of grandchild")
  -- Parent of "Sibling child" (line 6) is "Sibling project" (line 5).
  assert(deps.parent_of(lines, 6) == 5, "parent across project boundary")

  -- Direct children of "Project": [2, 4].
  local kids = deps.children_of(lines, 1)
  assert(#kids == 2 and kids[1] == 2 and kids[2] == 4, "direct children: " .. vim.inspect(kids))
  -- Descendants of "Project": [2, 3, 4].
  local desc = deps.descendants_of(lines, 1)
  assert(
    #desc == 3 and desc[1] == 2 and desc[2] == 3 and desc[3] == 4,
    "descendants: " .. vim.inspect(desc)
  )

  -- Previous siblings of "Second child" (line 4): [2].
  local prev = deps.previous_siblings_of(lines, 4)
  assert(#prev == 1 and prev[1] == 2, "previous siblings: " .. vim.inspect(prev))
  -- Previous siblings of "First child" (line 2): empty.
  prev = deps.previous_siblings_of(lines, 2)
  assert(#prev == 0, "first child has no prev siblings")
end

-- Parent blocked by active descendants

do
  local lines = {
    "* TODO Project",
    "** TODO First task",
    "** TODO Second task",
  }
  -- Parent (line 1) → DONE blocked by active children.
  local err = deps._check_lines(lines, 1, "DONE", SEQ, {})
  assert(err and err:match("descendant.*active"), "parent blocked: " .. tostring(err))
  -- Mark all children DONE → parent can transition.
  lines[2] = "** DONE First task"
  lines[3] = "** DONE Second task"
  err = deps._check_lines(lines, 1, "DONE", SEQ, {})
  assert(err == nil, "parent allowed after children DONE: " .. tostring(err))
end

-- NOBLOCKING child does not block parent

do
  local lines = {
    "* TODO Project",
    "** TODO Optional task",
    "   :PROPERTIES:",
    "   :NOBLOCKING: t",
    "   :END:",
    "** DONE Real task",
  }
  local err = deps._check_lines(lines, 1, "DONE", SEQ, {})
  assert(err == nil, "NOBLOCKING child should not block: " .. tostring(err))
end

-- ORDERED enforcement

do
  local lines = {
    "* TODO Project",
    "  :PROPERTIES:",
    "  :ORDERED: t",
    "  :END:",
    "** TODO First",
    "** TODO Second",
    "** TODO Third",
  }
  -- Marking "Second" (line 6) DONE while "First" is still TODO: blocked.
  local err = deps._check_lines(lines, 6, "DONE", SEQ, {})
  assert(err and err:match("ORDERED"), "ORDERED block on Second: " .. tostring(err))
  -- Mark First DONE → Second allowed.
  lines[5] = "** DONE First"
  err = deps._check_lines(lines, 6, "DONE", SEQ, {})
  assert(err == nil, "Second allowed after First DONE: " .. tostring(err))
  -- Third still blocked because Second isn't DONE yet.
  err = deps._check_lines(lines, 7, "DONE", SEQ, {})
  assert(err and err:match("ORDERED"), "Third still blocked: " .. tostring(err))
end

-- ORDERED on a non-parent headline does not affect non-children

do
  local lines = {
    "* TODO Independent",
    "* TODO Project",
    "  :PROPERTIES:",
    "  :ORDERED: t",
    "  :END:",
    "** TODO First",
  }
  -- "Independent" (line 1) marking DONE — its parent is nil, so ORDERED
  -- on Project doesn't matter.
  local err = deps._check_lines(lines, 1, "DONE", SEQ, {})
  assert(err == nil, "non-child unaffected by ORDERED: " .. tostring(err))
end

-- Checkbox dependencies (opt-in)

do
  local lines = {
    "* TODO Project",
    "  - [X] First step",
    "  - [ ] Second step",
    "  - [ ] Third step",
  }
  -- Default: checkbox check is OFF.
  local err = deps._check_lines(lines, 1, "DONE", SEQ, {})
  assert(err == nil, "checkbox check defaults off: " .. tostring(err))
  -- Opt in.
  err = deps._check_lines(lines, 1, "DONE", SEQ, { enforce_checkbox_dependencies = true })
  assert(err and err:match("checkbox"), "blocked on unchecked: " .. tostring(err))
  -- Tick the boxes → allowed.
  lines[3] = "  - [X] Second step"
  lines[4] = "  - [X] Third step"
  err = deps._check_lines(lines, 1, "DONE", SEQ, { enforce_checkbox_dependencies = true })
  assert(err == nil, "all boxes ticked: " .. tostring(err))
end

-- Disabled via config

do
  local lines = {
    "* TODO Project",
    "** TODO Active child",
  }
  local err = deps._check_lines(lines, 1, "DONE", SEQ, { enforce_dependencies = false })
  assert(err == nil, "disabled config skips checks: " .. tostring(err))
end

-- Transitions to non-DONE states are never blocked

do
  local lines = {
    "* TODO Project",
    "** TODO Active child",
  }
  -- Transition Project to DOING (active) — should never block even
  -- though descendant is active.
  local err = deps._check_lines(lines, 1, "DOING", SEQ, {})
  assert(err == nil, "active transitions never blocked: " .. tostring(err))
  -- Transition to no-state (clearing) — also allowed.
  err = deps._check_lines(lines, 1, nil, SEQ, {})
  assert(err == nil, "nil transition allowed: " .. tostring(err))
end

-- End-to-end: real buffer + todo._apply

do
  -- Suppress CLOSED-line insertion so line indices stay stable across
  -- the test (the dependency check itself is what we're validating,
  -- not the planning-block bookkeeping).
  local organ = require("organ")
  organ.config = organ.config or {}
  organ.config.todo = organ.config.todo or {}
  local saved_log_done = organ.config.todo.log_done
  organ.config.todo.log_done = nil

  local todo = require("organ.todo")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "* TODO Project",
    "** TODO First",
    "** TODO Second",
  })
  vim.bo[bufnr].buftype = "nofile"

  -- Try to mark Project DONE → should fail with dependency error.
  local err = todo._apply(bufnr, 1, "DONE")
  assert(err and err:lower():match("blocked"), "buffer-level block: " .. tostring(err))
  assert(
    vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "* TODO Project",
    "headline not mutated on block"
  )

  -- Mark children DONE then retry.
  assert(todo._apply(bufnr, 2, "DONE") == nil)
  assert(todo._apply(bufnr, 3, "DONE") == nil)
  err = todo._apply(bufnr, 1, "DONE")
  assert(err == nil, "parent transition succeeds after children: " .. tostring(err))
  assert(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]:match("^%* DONE"), "parent now DONE")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  organ.config.todo.log_done = saved_log_done
end

io.write("dependencies ok\n")
os.exit(0)
