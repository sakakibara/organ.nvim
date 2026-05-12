-- Unit test for the indent provider via organ.decoration.
--
-- Verifies that loading organ.indent registers a decoration provider,
-- attach() flips _attached so the provider's `enabled` gate opens, the
-- frame-local row map is built from on_win via the tree-sitter
-- headline walk, and the rendered inline virt_text matches the depth
-- cascade (each subordinate row picks up its enclosing headline's
-- level until a same-or-higher-level headline resets it).  Ephemeral
-- marks placed by on_line aren't visible to nvim_buf_get_extmarks
-- outside the real frame-rendering context, so the assertions go
-- through refresh(), which drives on_win full-buffer and writes
-- non-ephemeral marks.
--
-- Run via: nvim --headless -l tests/decoration_indent_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  indent = { enabled = true, shift_per_level = 2, hl_group = "Conceal" },
})
-- Loading the module triggers its top-level decoration.register({...}).
local indent = require("organ.indent")
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
check("indent provider registered", providers.indent ~= nil)
check("provider exposes ns", providers.indent and providers.indent.ns ~= nil)
check(
  "provider exposes on_win + on_line",
  providers.indent
    and type(providers.indent.on_win) == "function"
    and type(providers.indent.on_line) == "function"
)
check("provider has no on_lines", providers.indent and providers.indent.on_lines == nil)

-- `enabled` is gated on per-buffer attach.  A buffer that hasn't been
-- attached should report enabled=false even though the provider exists.
-- Use a non-org buffer so the ftplugin auto-attach path doesn't fire.
local pre_bufnr = vim.api.nvim_create_buf(false, true)
check("enabled() is false on un-attached buffer", providers.indent.enabled(pre_bufnr) == false)
vim.api.nvim_buf_delete(pre_bufnr, { force = true })

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Top", -- row 0, level 1 -> no pad
  "Body of top.", -- row 1, level 1 -> no pad
  "** Sub", -- row 2, level 2 -> 2 spaces
  "Body of sub.", -- row 3, level 2 -> 2 spaces
  "*** Deep", -- row 4, level 3 -> 4 spaces
  "Body of deep.", -- row 5, level 3 -> 4 spaces
  "* Next", -- row 6, level 1 -> no pad (cascade reset)
  "Body of next.", -- row 7, level 1 -> no pad
})

indent.attach(bufnr)
check("attach() sets _attached[bufnr]", indent._attached[bufnr] == true)
check("enabled() is true after attach()", providers.indent.enabled(bufnr) == true)

-- refresh writes non-ephemeral extmarks so nvim_buf_get_extmarks sees
-- them.  The ephemeral path is exercised by the real decoration-
-- provider callback at frame time.
indent.refresh(bufnr)

local marks = vim.api.nvim_buf_get_extmarks(bufnr, indent._ns, 0, -1, { details = true })
local pad_per_row = {}
for _, m in ipairs(marks) do
  local row = m[2]
  local details = m[4]
  if details and details.virt_text then
    pad_per_row[row] = #details.virt_text[1][1]
  end
end

check("row 0 (* Top): no pad", pad_per_row[0] == nil, "got " .. tostring(pad_per_row[0]))
check("row 1 (Body of top): no pad", pad_per_row[1] == nil, "got " .. tostring(pad_per_row[1]))
check("row 2 (** Sub): 2-space pad", pad_per_row[2] == 2, "got " .. tostring(pad_per_row[2]))
check("row 3 (body sub): 2-space pad", pad_per_row[3] == 2, "got " .. tostring(pad_per_row[3]))
check("row 4 (*** Deep): 4-space pad", pad_per_row[4] == 4, "got " .. tostring(pad_per_row[4]))
check("row 5 (body deep): 4-space pad", pad_per_row[5] == 4, "got " .. tostring(pad_per_row[5]))
check(
  "row 6 (* Next): cascade resets, no pad",
  pad_per_row[6] == nil,
  "got " .. tostring(pad_per_row[6])
)
check("row 7 (body next): no pad", pad_per_row[7] == nil, "got " .. tostring(pad_per_row[7]))

-- Verify the highlight group matches config.
local hl_ok = true
for _, m in ipairs(marks) do
  local details = m[4]
  if details and details.virt_text then
    local hl = details.virt_text[1][2]
    if hl ~= "Conceal" then
      hl_ok = false
    end
  end
end
check("all virt_text uses Conceal hl_group", hl_ok)

-- detach clears all extmarks in the namespace and drops _attached.
indent.detach(bufnr)
local after = vim.api.nvim_buf_get_extmarks(bufnr, indent._ns, 0, -1, {})
check("detach() clears all extmarks", #after == 0, "got " .. #after .. " leftover marks")
check("detach() drops _attached entry", indent._attached[bufnr] == nil)
check("enabled() is false after detach()", providers.indent.enabled(bufnr) == false)

vim.api.nvim_buf_delete(bufnr, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_indent_test: PASS")
os.exit(0)
