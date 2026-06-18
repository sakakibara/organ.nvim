-- Regression: every buffer-local keymap description must be Title-case (start
-- with an uppercase letter), matching the action-label convention.  The
-- structure keymaps (promote/demote/move subtree, e.g. \<) had lowercase
-- descriptions like "promote headline (alt)".
-- Run via: nvim --headless -l tests/keymap_desc_case_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({})

vim.fn.writefile({ "* Heading", "body" }, "/tmp/keymap_desc_case.org")
local b = vim.fn.bufadd("/tmp/keymap_desc_case.org")
vim.fn.bufload(b)
vim.bo[b].filetype = "org"

-- Mirror ftplugin/org.lua: install every feature's buffer-local keymaps.
for _, mod in ipairs({
  "core",
  "subtree",
  "inline_edit",
  "property",
  "table",
  "tag_select",
  "tempo",
}) do
  pcall(function()
    require("organ.ftplugin." .. mod).attach(b)
  end)
end
pcall(function()
  require("organ.keymaps").attach(b)
end)

local violations = {}
for _, mode in ipairs({ "n", "i", "x", "v" }) do
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, mode)) do
    -- A description starting with a lowercase letter breaks the Title-case
    -- convention.  Descriptions starting with a non-letter (digits, symbols,
    -- key tokens) are allowed.
    if m.desc and m.desc:match("^%l") then
      violations[#violations + 1] = string.format("[%s] %s -> %q", mode, m.lhs or "", m.desc)
    end
  end
end

assert(
  #violations == 0,
  "lowercase keymap descriptions (should be Title-case):\n  " .. table.concat(violations, "\n  ")
)

print("keymap_desc_case_test: PASS")
