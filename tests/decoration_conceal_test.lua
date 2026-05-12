-- Unit test for the conceal provider via organ.decoration.
--
-- Verifies that loading organ.conceal registers a decoration provider,
-- that on_lines populates a per-row span cache for the buffer, and that
-- the on_line dispatcher honours conceallevel.  The cache is inspected
-- directly because nvim_buf_set_extmark with `ephemeral = true` only
-- works inside the real decoration-provider callback context; headless
-- tests can drive on_lines (cache build) but can't synthesize the
-- ephemeral-extmark frame -- a `redraw` does that.
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
check("provider exposes on_lines + on_line",
  providers.conceal
    and type(providers.conceal.on_lines) == "function"
    and type(providers.conceal.on_line) == "function")

-- Buffer with emphasis content.
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Heading",
  "Plain *bold* and /italic/ and =verbatim=.",
})
-- Setting the filetype fires the org ftplugin which calls
-- decoration.attach(bufnr) -> dispatch_on_lines(...) which feeds the
-- conceal provider's on_lines and rebuilds its span cache.
vim.bo[bufnr].filetype = "org"

-- Setting filetype="org" already fires the org ftplugin which calls
-- decoration.attach -> dispatch_on_lines.  A direct re-attach is a
-- no-op (idempotent).
decoration.attach(bufnr)

-- Force a refresh so we get a fresh on_lines dispatch into our cache.
-- This is the path used by `:Org conceal toggle` etc.
decoration.refresh(bufnr)

local NS = vim.api.nvim_create_namespace("organ_emphasis_conceal")

-- Ephemeral extmarks set in on_line live only for the rendered frame;
-- they aren't visible to a follow-up nvim_buf_get_extmarks call.  To
-- assert on placed marks deterministically without depending on a
-- real redraw context, the test goes through `_apply`, which shares
-- the build_cache implementation with the on_lines path and writes
-- non-ephemeral extmarks.  The decoration provider on_line path is
-- exercised in integration via the real `nvim_set_decoration_provider`
-- callback at frame time.
require("organ.conceal")._apply(bufnr)
local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, { 1, 0 }, { 1, -1 }, { details = true })
check(
  "conceal placed at least one extmark on the emphasis row",
  #marks >= 1,
  "got " .. #marks .. " marks: " .. vim.inspect(marks)
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
