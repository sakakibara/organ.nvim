-- Import / export wiring:
--   * export (org -> md/html/latex/...) lives under the LocalLeader `\E`
--     group, bound in org buffers (you're always in org when exporting).
--   * import (markdown -> org) runs from the SOURCE buffer, so it lives in
--     the global keymaps (`<Leader>om`) and `:Org import markdown` with no
--     path converts the current buffer.
-- Run via: nvim --headless -l tests/import_export_keymaps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local km = require("organ.keymaps")

-- Export keymaps resolve to the right :Org export commands.
local defs = {}
for _, x in ipairs(km.defaults) do
  defs[x[1]] = x[2]
end
local expected = {
  ["<LocalLeader>Em"] = "Org export markdown",
  ["<LocalLeader>Eh"] = "Org export html",
  ["<LocalLeader>El"] = "Org export latex",
  ["<LocalLeader>Ep"] = "Org export pdf",
  ["<LocalLeader>Ea"] = "Org export ascii",
  ["<LocalLeader>Eo"] = "Org export opml",
  ["<LocalLeader>Eb"] = "Org export beamer",
  ["<LocalLeader>Et"] = "Org export texinfo",
}
for lhs, rhs in pairs(expected) do
  check(lhs .. " -> " .. rhs, defs[lhs] == rhs, "got " .. tostring(defs[lhs]))
end

-- The export prefix is a group labelled "export" (lowercase, per convention).
local groups = {}
for _, g in ipairs(km.groups) do
  groups[g[1]] = g.group
end
check(
  "<LocalLeader>E is the 'export' group",
  groups["<LocalLeader>E"] == "export",
  tostring(groups["<LocalLeader>E"])
)

-- Import is a default GLOBAL keymap (reachable from a markdown buffer),
-- not a LocalLeader org map.
check(
  "import_markdown has a default <Leader>o global keymap",
  require("organ.defaults").global_keymaps.import_markdown == "<Leader>om",
  tostring(require("organ.defaults").global_keymaps.import_markdown)
)
check(
  "no LocalLeader import binding",
  defs["<LocalLeader>Em"] ~= nil and defs["<LocalLeader>im"] == nil
)

-- `:Org import markdown` with no path converts the CURRENT buffer.
do
  local md = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(md)
  vim.bo[md].filetype = "markdown"
  vim.api.nvim_buf_set_lines(md, 0, -1, false, { "# Heading One", "", "Some **bold** body." })
  require("organ.import").commands["import markdown"].fn({ args = "", fargs = {} })
  local cur = vim.api.nvim_get_current_buf()
  check("import switched to a new buffer", cur ~= md)
  check("imported buffer is filetype=org", vim.bo[cur].filetype == "org")
  local out = vim.api.nvim_buf_get_lines(cur, 0, -1, false)
  local joined = table.concat(out, "\n")
  check("markdown H1 became an org heading", joined:match("^%*%s+Heading One") ~= nil, joined)
  check("current markdown buffer left intact", vim.api.nvim_buf_is_valid(md), "md buffer gone")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("import_export_keymaps_test: PASS")
os.exit(0)
