-- Per-file `#+TODO:` directive override (Emacs parity).
-- Run via: nvim --headless -l tests/todo_per_file_directive_test.lua

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

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "|", "DONE" } }, -- global default
})

local todo = require("organ.todo")

-- ---------------------------------------------------------------------------
-- File with `#+TODO:` directive uses the directive, not the global config.
-- ---------------------------------------------------------------------------
local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "#+TODO: NEW DOING | SHIPPED",
  "* NEW Feature work",
})
vim.bo[b].filetype = "org"

local seqs = todo.effective_sequences(b)
check("buffer dir parsed: 1 sequence", #seqs == 1)
check(
  "buffer dir parsed: NEW DOING SHIPPED order",
  seqs[1][1] == "NEW" and seqs[1][2] == "DOING" and seqs[1][3] == "|" and seqs[1][4] == "SHIPPED"
)

-- Cycling on the buffer should advance NEW -> DOING -> SHIPPED.
todo.cycle(b, 2)
check(
  "after cycle: NEW -> DOING",
  vim.api.nvim_buf_get_lines(b, 1, 2, false)[1] == "* DOING Feature work"
)
todo.cycle(b, 2)
check(
  "after second cycle: DOING -> SHIPPED",
  vim.api.nvim_buf_get_lines(b, 1, 2, false)[1] == "* SHIPPED Feature work"
)

vim.api.nvim_buf_delete(b, { force = true })

-- ---------------------------------------------------------------------------
-- Multiple `#+TODO:` lines accumulate as multi-sequence.
-- ---------------------------------------------------------------------------
local b2 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, {
  "#+TODO: TODO PROG | DONE",
  "#+TODO: BUG TRIAGE | FIXED",
  "* BUG Crash on save",
})
vim.bo[b2].filetype = "org"

local seqs2 = todo.effective_sequences(b2)
check("multi-dir: 2 sequences", #seqs2 == 2)
check("multi-dir: seq1 = TODO PROG | DONE", seqs2[1][1] == "TODO" and seqs2[1][4] == "DONE")
check("multi-dir: seq2 = BUG TRIAGE | FIXED", seqs2[2][1] == "BUG" and seqs2[2][4] == "FIXED")

-- Cycling on BUG should stay in seq2 (BUG -> TRIAGE), not jump to seq1.
todo.cycle(b2, 3)
check(
  "multi-dir: BUG -> TRIAGE (stays in seq2)",
  vim.api.nvim_buf_get_lines(b2, 2, 3, false)[1] == "* TRIAGE Crash on save"
)
todo.cycle(b2, 3)
check(
  "multi-dir: TRIAGE -> FIXED",
  vim.api.nvim_buf_get_lines(b2, 2, 3, false)[1] == "* FIXED Crash on save"
)

vim.api.nvim_buf_delete(b2, { force = true })

-- ---------------------------------------------------------------------------
-- No `#+TODO:` directive falls back to global config.
-- ---------------------------------------------------------------------------
local b3 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b3, 0, -1, false, { "* TODO Plain task" })
vim.bo[b3].filetype = "org"

local seqs3 = todo.effective_sequences(b3)
check("no directive: falls back to global", seqs3[1][1] == "TODO" and seqs3[1][3] == "DONE")

todo.cycle(b3, 1)
check(
  "no directive: cycle uses global TODO -> DONE",
  vim.api.nvim_buf_get_lines(b3, 0, 1, false)[1] == "* DONE Plain task"
)

vim.api.nvim_buf_delete(b3, { force = true })

-- ---------------------------------------------------------------------------
-- Annotated keywords in directive: `#+TODO: TODO(t!) | DONE(d)`.
-- ---------------------------------------------------------------------------
local b4 = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b4, 0, -1, false, {
  "#+TODO: TODO(t!) WAIT(w@) | DONE(d!)",
  "* TODO Annotated",
})
vim.bo[b4].filetype = "org"

-- Bare names in normalised output (annotations stripped).
local seqs4 = todo.effective_sequences(b4)
check("directive with annotations: bare TODO", seqs4[1][1] == "TODO")
check("directive with annotations: bare WAIT", seqs4[1][2] == "WAIT")
check("directive with annotations: bare DONE", seqs4[1][4] == "DONE")

vim.api.nvim_buf_delete(b4, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("todo_per_file_directive_test: PASS")
