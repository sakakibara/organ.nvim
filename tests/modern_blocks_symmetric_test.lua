-- Modern block frame: top and bottom must have the same total visual
-- width.  Old behavior used a fixed 30-char trailing rule on both
-- begin and end lines:
--   ╭── python ──────────────────────────────  (4 + 6 + 1 + 30 = 41 cols)
--   ╰──  ──────────────────────────────         (4 + 1 + 30 = 35 cols)
-- The bottom was shorter by len(label) + 1.  Pairing begin/end via
-- a kind-keyed stack lets the bottom recover the matching label
-- width and produce a same-length rule.
--
-- Run via: nvim --headless -l tests/modern_blocks_symmetric_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  modern = { blocks = true },
})
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

local NS = require("organ.modern.render").ns

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "#+begin_src python",
  "def hello():",
  "  print('hi')",
  "#+end_src",
  "",
  "#+begin_quote",
  "Body line.",
  "#+end_quote",
})
vim.bo[b].filetype = "org"
vim.cmd("doautocmd FileType org")
require("organ.modern.blocks")._apply(b)

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Recover the rendered top/bottom virt_text strings from the extmark
-- registry and compare display widths.
local function rendered_width(row)
  local marks = vim.api.nvim_buf_get_extmarks(b, NS, { row, 0 }, { row, -1 }, { details = true })
  local total = 0
  for _, m in ipairs(marks) do
    local d = m[4] or {}
    if d.virt_text then
      for _, seg in ipairs(d.virt_text) do
        total = total + vim.fn.strdisplaywidth(seg[1] or "")
      end
    end
  end
  return total
end

local top_src = rendered_width(0) -- #+begin_src python
local bot_src = rendered_width(3) -- #+end_src
check(
  "src_block: top and bottom have equal display width",
  top_src == bot_src and top_src > 0,
  ("top=%d bot=%d"):format(top_src, bot_src)
)

local top_q = rendered_width(5) -- #+begin_quote
local bot_q = rendered_width(7) -- #+end_quote
check(
  "quote_block: top and bottom have equal display width",
  top_q == bot_q and top_q > 0,
  ("top=%d bot=%d"):format(top_q, bot_q)
)

-- Each block's width is driven by its own content (label header,
-- widest body line, source line that the overlay must cover).  Two
-- blocks usually have different widths -- assert only that both are
-- non-zero.
check(
  "both blocks have non-zero width",
  top_src > 0 and top_q > 0,
  ("src=%d quote=%d"):format(top_src, top_q)
)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("modern_blocks_symmetric_test: PASS")
os.exit(0)
