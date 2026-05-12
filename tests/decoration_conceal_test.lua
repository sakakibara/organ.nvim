-- Unit test for the conceal provider via organ.decoration.
--
-- Verifies that loading organ.conceal registers a decoration provider
-- exposing on_win + on_line, that on_win populates a module-local
-- frame-row span map for the visible range, and that on_line emits
-- conceal extmarks for rows in that map.  `_apply` drives the full
-- buffer through the on_win path and places non-ephemeral marks so
-- headless tests can inspect them via nvim_buf_get_extmarks.
--
-- Run via: nvim --headless -l tests/decoration_conceal_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

-- Both grammars must be registered before any tree-walking runs.
local parser_path = require("organ.defaults").parser_path
local indexer = require("organ.indexer")
vim.treesitter.language.add("org", { path = parser_path })
vim.treesitter.language.add("org_inline", { path = indexer._inline_parser_path(parser_path) })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

-- Loading the module triggers its top-level decoration.register({...}).
require("organ.conceal")

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

-- Conceal provider must be registered.
local providers, _ = decoration._providers()
check("conceal provider registered", providers.conceal ~= nil)
check("provider exposes ns", providers.conceal and providers.conceal.ns ~= nil)
check(
  "provider exposes on_win + on_line",
  providers.conceal
    and type(providers.conceal.on_win) == "function"
    and type(providers.conceal.on_line) == "function"
)
check("provider has no on_lines", providers.conceal and providers.conceal.on_lines == nil)

-- Buffer with emphasis content.
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Heading",
  "Plain *bold* and /italic/ and =verbatim=.",
})
-- Setting the filetype fires the org ftplugin which calls
-- decoration.attach(bufnr).  The conceal provider has no on_lines
-- callback: its frame_map is rebuilt by on_win on each redraw frame
-- (driven below by _apply).
vim.bo[bufnr].filetype = "org"

-- decoration.attach is idempotent; the ftplugin already attached this
-- buffer above.
decoration.attach(bufnr)

-- Drive a synthetic frame to populate frame_map and place marks.
require("organ.conceal")._apply(bufnr)

local NS = vim.api.nvim_create_namespace("organ_emphasis_conceal")

local frame = require("organ.conceal")._frame_map()
-- Row 1 = "Plain *bold* and /italic/ and =verbatim=." (0-indexed)
-- Three pairs of single-byte markers => 6 spans.
check(
  "frame_map row 1 has 6 conceal spans",
  frame[1] and #frame[1] == 6,
  "got " .. (frame[1] and #frame[1] or "nil") .. " entries"
)

-- The non-ephemeral marks placed by _apply are inspectable directly.
local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, { 1, 0 }, { 1, -1 }, { details = true })
check(
  "non-ephemeral conceal marks placed on emphasis row",
  #marks >= 1,
  "got " .. #marks .. " marks"
)

-- Every mark should have conceal = "".
local all_conceal_empty = true
for _, m in ipairs(marks) do
  if m[4].conceal ~= "" then
    all_conceal_empty = false
    break
  end
end
check('every mark has conceal=""', all_conceal_empty)

-- toggle_element flips emphasis.bold and re-applies.  After toggling
-- bold off, the leading `*` on row 1 col 6 should NOT be concealed.
local function marks_at(row, col)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })) do
    local r, sc, det = m[2], m[3], m[4]
    local ec = det.end_col or (sc + 1)
    if r == row and sc <= col and col < ec then
      out[#out + 1] = m
    end
  end
  return out
end

check("bold open `*` initially concealed", #marks_at(1, 6) > 0)
local new_state = require("organ.conceal").toggle_element("bold")
check("toggle_element('bold') returns false", new_state == false)
check("bold open `*` NOT concealed after toggle off", #marks_at(1, 6) == 0)

vim.api.nvim_buf_delete(bufnr, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_conceal_test: PASS")
os.exit(0)
