-- Unit test for the indent module's mark placement.
--
-- Verifies that attach() subscribes the buffer for edit-driven refresh,
-- refresh() drives the tree-sitter headline walk to populate frame_map,
-- and writes persistent inline virt_text extmarks matching the depth
-- cascade (each subordinate row picks up its enclosing headline's
-- level until a same-or-higher-level headline resets it).  Marks are
-- non-ephemeral so nvim_buf_get_extmarks reads them directly -- no
-- decoration-provider race.
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
  modern = { bullets = false },
  stars = { hide = false },
})
local indent = require("organ.indent")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

check("indent module exposes a namespace", indent._ns ~= nil)
check(
  "indent module exposes attach/detach",
  type(indent.attach) == "function" and type(indent.detach) == "function"
)

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Top", -- row 0, level 1, heading pad = 0
  "Body of top.", -- row 1, level 1 body, pad = 0 + 1 + 1 = 2
  "** Sub", -- row 2, level 2, heading pad = 2
  "Body of sub.", -- row 3, level 2 body, pad = 2 + 2 + 1 = 5
  "*** Deep", -- row 4, level 3, heading pad = 4
  "Body of deep.", -- row 5, level 3 body, pad = 4 + 3 + 1 = 8
  "* Next", -- row 6, level 1, heading pad = 0 (cascade reset)
  "Body of next.", -- row 7, level 1 body, pad = 2
})

indent.attach(bufnr)
check("attach() sets _attached[bufnr]", indent._attached[bufnr] == true)

-- refresh writes non-ephemeral extmarks so nvim_buf_get_extmarks sees them.
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

check("row 0 (* Top): no heading pad", pad_per_row[0] == nil, "got " .. tostring(pad_per_row[0]))
check("row 1 (Body of top): body pad = 2", pad_per_row[1] == 2, "got " .. tostring(pad_per_row[1]))
check("row 2 (** Sub): heading pad = 2", pad_per_row[2] == 2, "got " .. tostring(pad_per_row[2]))
check("row 3 (body sub): body pad = 5", pad_per_row[3] == 5, "got " .. tostring(pad_per_row[3]))
check("row 4 (*** Deep): heading pad = 4", pad_per_row[4] == 4, "got " .. tostring(pad_per_row[4]))
check("row 5 (body deep): body pad = 8", pad_per_row[5] == 8, "got " .. tostring(pad_per_row[5]))
check(
  "row 6 (* Next): cascade resets, no heading pad",
  pad_per_row[6] == nil,
  "got " .. tostring(pad_per_row[6])
)
check("row 7 (body next): body pad = 2", pad_per_row[7] == 2, "got " .. tostring(pad_per_row[7]))

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

vim.api.nvim_buf_delete(bufnr, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_indent_test: PASS")
os.exit(0)
