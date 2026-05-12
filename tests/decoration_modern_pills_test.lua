-- Unit test for the modern.pills provider via organ.decoration.
--
-- Verifies that loading organ.modern.pills registers a decoration
-- provider, the per-buffer row cache is built from on_lines via the
-- tree-sitter headline_line + timestamp walk, and on_line emits the
-- right hl extmarks for each row (TODO keyword pill, active /
-- inactive timestamp pills).  Ephemeral marks placed by on_line
-- aren't visible to nvim_buf_get_extmarks outside the real frame-
-- rendering context, so the assertions go through _apply, which
-- shares build_cache with on_lines but writes non-ephemeral marks.
--
-- Run via: nvim --headless -l tests/decoration_modern_pills_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Load both parsers (block + inline).  Timestamps live in the
-- org_inline injected grammar; without it the timestamp walk yields
-- nothing.
local parser_path = require("organ.defaults").parser_path
local inline_path = (parser_path:gsub("/org%.so$", "/org_inline.so"))
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = inline_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
  modern = { pills = true },
})
-- Loading the module triggers its top-level decoration.register({...}).
require("organ.modern.pills")

local decoration = require("organ.decoration")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local providers, _ = decoration._providers()
check("modern_pills provider registered", providers.modern_pills ~= nil)
check("provider exposes ns", providers.modern_pills and providers.modern_pills.ns ~= nil)
check(
  "provider exposes on_lines + on_line",
  providers.modern_pills
    and type(providers.modern_pills.on_lines) == "function"
    and type(providers.modern_pills.on_line) == "function"
)

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* TODO Heading with timestamp <2026-05-12>",
  "Body",
  "* DONE Other heading [2026-05-11]",
})

decoration.attach(bufnr)
-- _apply rebuilds the cache + writes non-ephemeral marks so
-- nvim_buf_get_extmarks can see them.  The ephemeral path is exercised
-- by the real decoration-provider callback at frame time.
require("organ.modern.pills")._apply(bufnr)

local NS = vim.api.nvim_create_namespace("organ_modern_pills")
local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })

local by_row = {}
for _, m in ipairs(marks) do
  by_row[m[2]] = by_row[m[2]] or {}
  table.insert(by_row[m[2]], m)
end

local function find_hl(row, hl_pat)
  for _, m in ipairs(by_row[row] or {}) do
    local g = (m[4] or {}).hl_group
    if g and g:find(hl_pat) then
      return m
    end
  end
end

-- Row 0: `* TODO Heading with timestamp <2026-05-12>` -- expect a
-- TODO keyword pill at cols 2..6 and an active timestamp pill on
-- the `<2026-05-12>` span.
local todo_mark = find_hl(0, "pill%.todo$")
check("row 0: TODO keyword pill present", todo_mark ~= nil)
if todo_mark then
  local col = todo_mark[3]
  local end_col = (todo_mark[4] or {}).end_col
  check("row 0: TODO pill spans exactly 4 bytes (TODO)", end_col and (end_col - col) == 4)
  check("row 0: TODO pill starts at col 2 (after `* `)", col == 2)
end

local ts0 = find_hl(0, "pill%.timestamp$")
check("row 0: active timestamp pill present", ts0 ~= nil)
if ts0 then
  -- `<2026-05-12>` is 12 bytes.
  local col = ts0[3]
  local end_col = (ts0[4] or {}).end_col
  check(
    "row 0: timestamp pill spans 12 bytes (<2026-05-12>)",
    end_col and (end_col - col) == 12,
    "got " .. tostring(end_col and (end_col - col))
  )
end

-- Row 1: `Body` -- no pills expected.
check(
  "row 1 (Body): no pill marks",
  by_row[1] == nil or #by_row[1] == 0,
  "got " .. (by_row[1] and #by_row[1] or 0) .. " marks"
)

-- Row 2: `* DONE Other heading [2026-05-11]` -- DONE pill + inactive
-- timestamp pill.
local done_mark = find_hl(2, "pill%.done$")
check("row 2: DONE keyword pill present", done_mark ~= nil)
if done_mark then
  local col = done_mark[3]
  local end_col = (done_mark[4] or {}).end_col
  check("row 2: DONE pill spans 4 bytes", end_col and (end_col - col) == 4)
end

local ts2 = find_hl(2, "pill%.timestamp$")
check("row 2: inactive timestamp pill present", ts2 ~= nil)
if ts2 then
  -- `[2026-05-11]` is 12 bytes.
  local col = ts2[3]
  local end_col = (ts2[4] or {}).end_col
  check(
    "row 2: inactive timestamp pill spans 12 bytes ([2026-05-11])",
    end_col and (end_col - col) == 12
  )
end

-- A buffer that is not org filetype should yield no decoration.
local plain = vim.api.nvim_create_buf(false, true)
vim.bo[plain].filetype = "text"
vim.api.nvim_buf_set_lines(plain, 0, -1, false, {
  "* TODO not org",
  "<2026-05-12> not a real timestamp here",
})
decoration.attach(plain)
require("organ.modern.pills")._apply(plain)
local plain_marks = vim.api.nvim_buf_get_extmarks(plain, NS, 0, -1, {})
check("non-org buffer: no marks", #plain_marks == 0)

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.api.nvim_buf_delete(plain, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_modern_pills_test: PASS")
os.exit(0)
