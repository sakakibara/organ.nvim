-- org-modern pills: TODO keywords + timestamps render with reverse-
-- video pill highlight via extmarks. Cosmetic only — no buffer text
-- changes.
-- Run via: nvim --headless -l tests/modern_pills_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "WAIT", "|", "DONE", "CANCELLED" } },
  modern = { pills = true },
})

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* TODO Buy groceries",
  "* NEXT Code review",
  "* DONE Buy bread",
  "Body text scheduled <2026-05-04 Mon> noon.",
  "Reviewed [2026-05-03 Sun].",
  "* Plain heading no keyword",
})
vim.bo[bufnr].filetype = "org"
vim.api.nvim_set_current_buf(bufnr)

local pills = require("organ.modern.pills")
pills.attach(bufnr)
vim.wait(50) -- drain deferred initial apply

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local NS = require("organ.modern.render").ns
check("render namespace available", NS ~= nil)

local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })

local function mark_on(row, hl_pat)
  for _, m in ipairs(marks) do
    if m[2] == row and m[4] and m[4].hl_group and m[4].hl_group:find(hl_pat) then
      return m
    end
  end
end

check("row 0 (* TODO …): pill mark for TODO", mark_on(0, "pill%.todo$") ~= nil)
check("row 1 (* NEXT …): pill mark for NEXT", mark_on(1, "pill%.next$") ~= nil)
check("row 2 (* DONE …): pill mark for DONE", mark_on(2, "pill%.done$") ~= nil)
check(
  "no timestamp pill marks (dates owns timestamps now)",
  mark_on(3, "pill%.timestamp") == nil and mark_on(4, "pill%.timestamp") == nil
)
check("row 5 (no keyword): no pill mark", mark_on(5, "pill") == nil)

-- Verify pill mark covers EXACTLY the keyword bytes (not the whole line).
local todo_mark = mark_on(0, "pill%.todo$")
local todo_col_start = todo_mark[3]
local todo_col_end = todo_mark[4].end_col
check(
  "TODO pill spans exactly 4 bytes",
  (todo_col_end - todo_col_start) == 4,
  "got " .. tostring(todo_col_end - todo_col_start)
)

-- Highlight group should be defined with reverse=true (the pill effect).
local hl = vim.api.nvim_get_hl(0, { name = "@organ.modern.badge.pill.todo" })
check("pill hl group has reverse=true", hl.reverse == true, "got " .. vim.inspect(hl))

-- detach() removes them.
pills.detach(bufnr)
local after = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
check("detach() clears marks", #after == 0)

-- Keywords come from the EFFECTIVE sequences: annotated config entries
-- are stripped, and a buffer `#+TODO:` directive wins over config.
local function marks_matching(pat)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })) do
    if m[4] and m[4].hl_group and m[4].hl_group:find(pat) then
      n = n + 1
    end
  end
  return n
end
local saved_seq = require("organ").config.todo.sequence
require("organ").config.todo.sequence = { "TODO(t)", "NEXT(n)", "|", "DONE(d)" }
pills._apply(bufnr)
check(
  "annotated todo.sequence: TODO/NEXT/DONE still get pills",
  marks_matching("pill%.todo$") > 0
    and marks_matching("pill%.next$") > 0
    and marks_matching("pill%.done$") > 0,
  "todo="
    .. marks_matching("pill%.todo$")
    .. " next="
    .. marks_matching("pill%.next$")
    .. " done="
    .. marks_matching("pill%.done$")
)
vim.api.nvim_buf_set_lines(
  bufnr,
  0,
  -1,
  false,
  { "#+TODO: WAIT | DONE", "* WAIT Blocked", "* TODO Old" }
)
pills._apply(bufnr)
check("buffer #+TODO keyword WAIT gets a pill", marks_matching("pill%.wait$") > 0)
check("keyword absent from the buffer's #+TODO gets no pill", marks_matching("pill%.todo$") == 0)
require("organ").config.todo.sequence = saved_seq

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_pills_test: PASS")
