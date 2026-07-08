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
local ns_blocks = NS["organ_modern_blocks"]
-- Bullets and pills both render through the persistent engine, so their
-- marks share one namespace; blocks is still an ephemeral provider.
local ns_engine = require("organ.modern.render").ns

check("engine  namespace registered", ns_engine ~= nil)
check("blocks  namespace registered", ns_blocks ~= nil)

local function count_marks(ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

local n_engine = count_marks(ns_engine) -- bullets + pills
local n_blocks = count_marks(ns_blocks)

-- Bullets: 1+2+3 star-marks over the three headlines = 6.
-- Pills: 3 keyword pills * (body + 2 caps) = 9. Combined engine marks = 15.
check("engine produced bullets + pills marks", n_engine >= 15, "got " .. n_engine)
check(
  "blocks produced extmarks (1 begin_src + 1 end_src + 1 body × 2 bars = 4)",
  n_blocks == 4,
  "got " .. n_blocks
)

-- conceallevel was bumped (bullets + blocks both need it).
check("conceallevel >= 2 after combined attach", vim.wo.conceallevel >= 2)

-- detach() removes marks from both namespaces.
modern.detach(bufnr)
check("engine cleared after combined detach", count_marks(ns_engine) == 0)
check("blocks  cleared after combined detach", count_marks(ns_blocks) == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_stack_test: PASS")
