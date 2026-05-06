-- indent.attach + refresh apply inline-virt-text extmarks per line based on
-- enclosing section level.
-- Run via: nvim --headless -l tests/indent_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local b = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* Top", -- line 1, level 1 → 0 spaces
  "Body of top.", -- line 2, level 1 → 0 spaces
  "** Sub", -- line 3, level 2 → 2 spaces
  "Body of sub.", -- line 4, level 2 → 2 spaces
  "*** Deep", -- line 5, level 3 → 4 spaces
  "Body of deep.", -- line 6, level 3 → 4 spaces
})
vim.api.nvim_buf_set_option(b, "filetype", "org")
vim.api.nvim_set_current_buf(b)

local indent = require("organ.indent")
indent.attach(b)
indent.refresh(b)

local marks = vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, { details = true })
-- Build map: line (1-based) → number of virt_text spaces.
local pad_per_line = {}
for _, m in ipairs(marks) do
  local lnum_0 = m[2]
  local details = m[4]
  if details and details.virt_text then
    local pad_str = details.virt_text[1][1]
    pad_per_line[lnum_0 + 1] = #pad_str
  end
end

-- Headlines themselves get the indent (so deeper stars shift right visually).
assert(
  pad_per_line[1] == 0 or pad_per_line[1] == nil,
  "level-1 headline pad: got " .. (pad_per_line[1] or 0)
)
assert(
  pad_per_line[2] == 0 or pad_per_line[2] == nil,
  "level-1 body pad:     got " .. (pad_per_line[2] or 0)
)
assert(pad_per_line[3] == 2, "level-2 headline pad: got " .. (pad_per_line[3] or -1))
assert(pad_per_line[4] == 2, "level-2 body pad:     got " .. (pad_per_line[4] or -1))
assert(pad_per_line[5] == 4, "level-3 headline pad: got " .. (pad_per_line[5] or -1))
assert(pad_per_line[6] == 4, "level-3 body pad:     got " .. (pad_per_line[6] or -1))

-- detach clears all extmarks in the namespace.
indent.detach(b)
local after = vim.api.nvim_buf_get_extmarks(b, indent._ns, 0, -1, {})
assert(#after == 0, "expected no extmarks after detach; got " .. #after)

io.write("indent ok\n")
os.exit(0)
