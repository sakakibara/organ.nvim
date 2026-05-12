-- Unit test for the modern.blocks provider via organ.decoration.
--
-- Verifies that loading organ.modern.blocks registers a decoration
-- provider, the per-buffer two-layer cache (block_ranges + per-row
-- kind map) is built from on_lines via the tree-sitter `*_block` walk,
-- and on_line emits the right extmark shape for each row (top corner
-- overlay, body bars, bottom corner overlay).  Ephemeral marks placed
-- by on_line aren't visible to nvim_buf_get_extmarks outside the real
-- frame-rendering context, so the assertions go through _apply, which
-- shares build_cache with on_lines but writes non-ephemeral marks.
--
-- Run via: nvim --headless -l tests/decoration_modern_blocks_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  modern = { blocks = true },
})
-- Loading the module triggers its top-level decoration.register({...}).
require("organ.modern.blocks")

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
check("modern_blocks provider registered", providers.modern_blocks ~= nil)
check("provider exposes ns", providers.modern_blocks and providers.modern_blocks.ns ~= nil)
check(
  "provider exposes on_win + on_line",
  providers.modern_blocks
    and type(providers.modern_blocks.on_win) == "function"
    and type(providers.modern_blocks.on_line) == "function"
)
check("provider has no on_lines", providers.modern_blocks and providers.modern_blocks.on_lines == nil)

-- The provider gate reads `cfg.modern.blocks`; with the setup above
-- that's truthy.  Verify it returns true for any buffer (the gate is
-- config-level, not per-buffer attach state).
local probe = vim.api.nvim_create_buf(false, true)
check("enabled() respects cfg.modern.blocks", providers.modern_blocks.enabled(probe) == true)
vim.api.nvim_buf_delete(probe, { force = true })

-- A 5-line src block plus a quote block (greater_block) so we exercise
-- both the directly-named node types AND the greater_block fallback.
local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "* Heading", -- row 0 (no decoration)
  "#+begin_src python", -- row 1 (top)
  "def f():", -- row 2 (body)
  "    pass", -- row 3 (body)
  "#+end_src", -- row 4 (bot)
  "", -- row 5
  "#+begin_quote", -- row 6 (top, via greater_block)
  "Q line one.", -- row 7 (body)
  "Q line two.", -- row 8 (body)
  "#+end_quote", -- row 9 (bot)
})

decoration.attach(bufnr)
-- _apply rebuilds the cache + writes non-ephemeral marks so
-- nvim_buf_get_extmarks can see them.  The ephemeral path is exercised
-- by the real decoration-provider callback at frame time.
require("organ.modern.blocks")._apply(bufnr)

local NS = vim.api.nvim_create_namespace("organ_modern_blocks")
local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })

local by_row = {}
for _, m in ipairs(marks) do
  by_row[m[2]] = by_row[m[2]] or {}
  table.insert(by_row[m[2]], m)
end

-- Helper: does row's combined virt_text contain `needle`?
local function row_has(row, needle)
  for _, m in ipairs(by_row[row] or {}) do
    local d = m[4] or {}
    if d.virt_text then
      for _, seg in ipairs(d.virt_text) do
        if seg[1] and seg[1]:find(needle, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

-- Top corner at the `#+begin_src` row.
check("row 1 (#+begin_src): has top corner '┌'", row_has(1, "┌"))
check("row 1 (#+begin_src): has label 'python'", row_has(1, "python"))

-- Body bars at the inner content rows.  Two inline virt_text marks per
-- body row: `│ ` on the left, ` <pad>│` on the right.
check("row 2 (def f): has 2 body marks (left+right bar)", #(by_row[2] or {}) == 2)
check("row 3 (pass): has 2 body marks (left+right bar)", #(by_row[3] or {}) == 2)
check("row 2 has vertical bar '│'", row_has(2, "│"))
check("row 3 has vertical bar '│'", row_has(3, "│"))

-- Bottom corner at the `#+end_src` row.
check("row 4 (#+end_src): has bottom corner '└'", row_has(4, "└"))
check("row 4 (#+end_src): has bottom corner '┘'", row_has(4, "┘"))

-- Heading row (0) and blank row (5) get no decoration.
check("row 0 (* Heading): no decoration", (by_row[0] == nil) or (#by_row[0] == 0))
check("row 5 (blank): no decoration", (by_row[5] == nil) or (#by_row[5] == 0))

-- greater_block (#+begin_quote / #+end_quote) is detected too.
check("row 6 (#+begin_quote): has top corner '┌'", row_has(6, "┌"))
check("row 6 (#+begin_quote): has label 'quote'", row_has(6, "quote"))
check("row 7 (Q line one): has body bar '│'", row_has(7, "│"))
check("row 8 (Q line two): has body bar '│'", row_has(8, "│"))
check("row 9 (#+end_quote): has bottom corner '└'", row_has(9, "└"))

-- A buffer that is not org filetype should yield no decoration.
local plain = vim.api.nvim_create_buf(false, true)
vim.bo[plain].filetype = "text"
vim.api.nvim_buf_set_lines(plain, 0, -1, false, {
  "#+begin_src python",
  "x = 1",
  "#+end_src",
})
decoration.attach(plain)
require("organ.modern.blocks")._apply(plain)
local plain_marks = vim.api.nvim_buf_get_extmarks(plain, NS, 0, -1, {})
check("non-org buffer: no marks", #plain_marks == 0)

vim.api.nvim_buf_delete(bufnr, { force = true })
vim.api.nvim_buf_delete(plain, { force = true })

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("decoration_modern_blocks_test: PASS")
os.exit(0)
