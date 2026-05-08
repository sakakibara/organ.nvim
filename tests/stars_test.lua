-- Star concealment (org-hide-leading-stars equivalent).
--
-- Asserts that leading-star bytes get a conceal extmark on each
-- headline, with the trailing star left visible.
--
-- Run via: nvim --headless -l tests/stars_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  stars = { hide = true },
})

-- Tests run without nvim-treesitter, so we register the org grammar
-- against the binary that organ ships with itself.
local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Level one",
  "** Level two",
  "*** Level three",
  "Some body text.",
  "**** Level four",
})
vim.bo[bufnr].filetype = "org"
vim.api.nvim_set_current_buf(bufnr)

local stars = require("organ.stars")
stars.attach(bufnr)
vim.wait(0) -- drain deferred initial apply

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local NS = vim.api.nvim_get_namespaces()["organ_stars_hide"]
check("namespace registered", NS ~= nil)

local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })

-- Group marks by row.
local by_row = {}
for _, m in ipairs(marks) do
  local row = m[2]
  by_row[row] = (by_row[row] or 0) + 1
end

-- Level 1 (`* Level one`): N-1 = 0 conceal marks.
check("row 0 (* Level one): 0 conceal marks", (by_row[0] or 0) == 0)
-- Level 2 (`** Level two`): N-1 = 1 conceal mark.
check("row 1 (** Level two): 1 conceal mark", (by_row[1] or 0) == 1)
-- Level 3 (`*** Level three`): N-1 = 2 conceal marks.
check("row 2 (*** Level three): 2 conceal marks", (by_row[2] or 0) == 2)
-- Body text: 0 marks.
check("row 3 (body text): 0 conceal marks", (by_row[3] or 0) == 0)
-- Level 4 (`**** Level four`): N-1 = 3 conceal marks.
check("row 4 (**** Level four): 3 conceal marks", (by_row[4] or 0) == 3)

-- Each mark replaces a single byte with " ".
for _, m in ipairs(marks) do
  local details = m[4] or {}
  check(
    ("mark at (row=%d, col=%d) conceals to space"):format(m[2], m[3]),
    details.conceal == " ",
    "got conceal=" .. tostring(details.conceal)
  )
end

-- conceallevel was bumped to 2.
check("window conceallevel set to >= 2", vim.wo.conceallevel >= 2)

-- detach() removes the marks.
stars.detach(bufnr)
local after = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
check("detach() clears marks", #after == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("stars_test: PASS")
