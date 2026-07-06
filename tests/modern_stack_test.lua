-- org-modern stages combined: bullets + blocks + pills all attached
-- to the same buffer at the same time. Each lives in its own
-- extmark namespace, so they should coexist without overwriting
-- each other's marks.
--
-- Run via: nvim --headless -l tests/modern_stack_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
  todo = { sequence = { "TODO", "NEXT", "|", "DONE" } },
  modern = { bullets = true, blocks = true, pills = true },
})

local parser_path = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = parser_path })

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* TODO Top-level task <2026-05-04 Mon>",
  "** NEXT Sub-task",
  "*** DONE Done note",
  "",
  "#+begin_src lua",
  "  print('hi')",
  "#+end_src",
  "",
  "Body text [2026-05-03 Sun] inactive ts.",
})
vim.bo[bufnr].filetype = "org"
vim.api.nvim_set_current_buf(bufnr)

local modern = require("organ.modern")
modern.attach(bufnr)
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

local NS = vim.api.nvim_get_namespaces()
local ns_bullets = NS["organ_modern_bullets"]
local ns_blocks = NS["organ_modern_blocks"]
-- Pills render through the persistent engine (organ_modern_render), not the
-- ephemeral decoration provider, so their marks live in the engine namespace.
local ns_pills = require("organ.modern.render").ns

check("bullets namespace registered", ns_bullets ~= nil)
check("blocks  namespace registered", ns_blocks ~= nil)
check("pills   namespace registered", ns_pills ~= nil)

local function count_marks(ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

-- Each stage independently produces its own marks; combined attach
-- should produce > 0 marks per namespace.
local n_bullets = count_marks(ns_bullets)
local n_blocks = count_marks(ns_blocks)
local n_pills = count_marks(ns_pills)

check(
  "bullets produced extmarks (3 headlines × 1+ marks each)",
  n_bullets >= 6,
  "got " .. n_bullets
)
check(
  "blocks produced extmarks (1 begin_src + 1 end_src + 1 body × 2 bars = 4)",
  n_blocks == 4,
  "got " .. n_blocks
)
-- Each keyword pill is a body + two rounded caps (3 marks); timestamps are
-- plain reverse boxes (1 mark).  3 keywords * 3 + 2 timestamps = 11.
check("pills produced extmarks (3 TODO kw pills + 2 timestamps)", n_pills == 11, "got " .. n_pills)

-- conceallevel was bumped (bullets + blocks both need it).
check("conceallevel >= 2 after combined attach", vim.wo.conceallevel >= 2)

-- detach() removes ALL three.
modern.detach(bufnr)
check("bullets cleared after combined detach", count_marks(ns_bullets) == 0)
check("blocks  cleared after combined detach", count_marks(ns_blocks) == 0)
check("pills   cleared after combined detach", count_marks(ns_pills) == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_stack_test: PASS")
