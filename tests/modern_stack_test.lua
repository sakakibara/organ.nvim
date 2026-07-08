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

-- Bullets, pills, and blocks all render through the persistent engine now,
-- so their marks share one namespace.
local ns_engine = require("organ.modern.render").ns
check("engine namespace registered", ns_engine ~= nil)

local function count_marks(ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

local n_engine = count_marks(ns_engine) -- bullets + pills + block frame
-- Bullets 6 (1+2+3 stars) + pills 9 (3 kw * 3) + block frame 4
-- (top + bottom overlay + 1 body line * 2 inline bars) = 19.
check("engine produced bullets + pills + block marks", n_engine >= 19, "got " .. n_engine)

-- conceallevel was bumped (the engine raises it for its conceal marks).
check("conceallevel >= 2 after combined attach", vim.wo.conceallevel >= 2)

modern.detach(bufnr)
check("engine cleared after combined detach", count_marks(ns_engine) == 0)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_stack_test: PASS")
