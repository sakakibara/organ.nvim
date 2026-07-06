-- TODO keywords are colored by semantic bucket (org state -> theme
-- diagnostic group), not by heading-collision avoidance:
--   actionable (TODO/NEXT/...)     -> DiagnosticError  (red)
--   blocked    (WAITING/HOLD/...)  -> DiagnosticWarn   (yellow)
--   done       (DONE)              -> DiagnosticOk      (green)
--   cancelled  (CANCELLED/CLOSED)  -> Comment           (grey)
-- Distinction from a same-hue heading is structural (the pill badge), so a
-- semantic color is kept even when a heading shares it.
--
-- Run via: nvim --headless -l tests/highlights_todo_bucket_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
local hl = require("organ.highlights")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- 1. Bucket classification (pure, case-insensitive; done-section aware).
check("TODO -> actionable", hl.todo_bucket("TODO", false) == "actionable")
check("NEXT -> actionable", hl.todo_bucket("NEXT", false) == "actionable")
check("PROJ -> actionable", hl.todo_bucket("PROJ", false) == "actionable")
check("WAITING -> blocked", hl.todo_bucket("WAITING", false) == "blocked")
check("HOLD -> blocked", hl.todo_bucket("HOLD", false) == "blocked")
check("hold (lowercase) -> blocked", hl.todo_bucket("hold", false) == "blocked")
check("DONE -> done", hl.todo_bucket("DONE", true) == "done")
check("CANCELLED -> cancelled", hl.todo_bucket("CANCELLED", true) == "cancelled")
check("CLOSED -> cancelled", hl.todo_bucket("CLOSED", true) == "cancelled")
-- The done-section flag decides active-vs-done; a custom done keyword that
-- isn't a known "cancelled" name is a plain done (green).
check("SHIPPED (done section) -> done", hl.todo_bucket("SHIPPED", true) == "done")

-- 2. Bucket -> highlight group, with the diagnostic groups styled.
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xEE0000 })
vim.api.nvim_set_hl(0, "DiagnosticWarn", { fg = 0xEEEE00 })
vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = 0x00CC00 })
vim.api.nvim_set_hl(0, "Comment", { fg = 0x888888 })
check("actionable -> DiagnosticError", hl.todo_bucket_link("actionable") == "DiagnosticError")
check("blocked -> DiagnosticWarn", hl.todo_bucket_link("blocked") == "DiagnosticWarn")
check("done -> DiagnosticOk", hl.todo_bucket_link("done") == "DiagnosticOk")
check("cancelled -> Comment", hl.todo_bucket_link("cancelled") == "Comment")

-- Resolved colors are what pills / text use.
check("actionable resolves red", hl.resolved_fg(hl.todo_bucket_link("actionable")) == 0xEE0000)
check("cancelled resolves grey", hl.resolved_fg(hl.todo_bucket_link("cancelled")) == 0x888888)

-- 3. Fallback chain: themes without the newer DiagnosticOk still get green.
vim.api.nvim_set_hl(0, "DiagnosticOk", {}) -- unstyle
vim.api.nvim_set_hl(0, "@diff.plus", {}) -- unstyle the next in chain too
vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x00AA00 })
check(
  "done falls back to DiffAdd when DiagnosticOk/@diff.plus unstyled",
  hl.todo_bucket_link("done") == "DiffAdd",
  hl.todo_bucket_link("done")
)

-- 4. No heading-collision avoidance: a keyword keeps its semantic color even
--    when a heading level shares that exact color.
vim.api.nvim_set_hl(0, "DiagnosticError", { fg = 0xEE0000 })
vim.api.nvim_set_hl(0, "OrgHeadRed", { fg = 0xEE0000 })
vim.api.nvim_set_hl(0, "@org.heading.1", { link = "OrgHeadRed" })
check(
  "actionable stays red despite a red heading-1",
  hl.resolved_fg(hl.todo_bucket_link("actionable")) == 0xEE0000
)

-- 5. Per-keyword groups link to their bucket (integration through register).
for _, g in ipairs({ "todo", "waiting", "done", "cancelled" }) do
  pcall(vim.api.nvim_set_hl, 0, "@org.todo." .. g, {}) -- clear so default set applies
end
hl.register_todo_keywords({ "TODO", "WAITING", "|", "DONE", "CANCELLED" })
local function fg(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false }).fg
end
check("@org.todo.todo -> red", fg("@org.todo.todo") == 0xEE0000, tostring(fg("@org.todo.todo")))
check("@org.todo.waiting -> yellow", fg("@org.todo.waiting") == 0xEEEE00)
check("@org.todo.done -> green (DiffAdd fallback)", fg("@org.todo.done") == 0x00AA00)
check("@org.todo.cancelled -> grey", fg("@org.todo.cancelled") == 0x888888)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("highlights_todo_bucket_test: PASS")
os.exit(0)
