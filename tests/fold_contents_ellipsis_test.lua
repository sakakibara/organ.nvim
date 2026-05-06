-- CONTENTS view places a virt_text "…" extmark at end-of-line on
-- every heading whose body is hidden, so the heading reads `* H…`
-- exactly like its OVERVIEW counterpart (where `emacs_foldtext`
-- renders the same suffix).  Headings whose body is all-blank get
-- no ellipsis (matches `fold_has_real_content`).  Highlight is the
-- per-level heading-title capture so the ellipsis matches the
-- heading color, not a separate Folded gray.
--
-- Run via: nvim --headless -l tests/fold_contents_ellipsis_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
})

local contents = require("organ.fold.contents")

if not contents.is_supported() then
  print("(skipped: nvim does not support `conceal_lines` extmark)")
  print("fold_contents_ellipsis_test: SKIP")
  os.exit(0)
end

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b)
vim.api.nvim_buf_set_lines(b, 0, -1, false, {
  "* H1 with body", -- 1
  "body line 1", -- 2
  "body line 2", -- 3
  "* H2 empty", -- 4
  "* H3 with body", -- 5
  "body of H3", -- 6
})
vim.bo[b].filetype = "org"

contents.enter(b)

local NS = vim.api.nvim_get_namespaces().organ_fold_contents
local marks = vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })

local function virt_eol_at(row)
  for _, m in ipairs(marks) do
    if m[2] == row then
      local d = m[4] or {}
      if d.virt_text and d.virt_text_pos == "eol" then
        local txt, hl = "", nil
        for _, seg in ipairs(d.virt_text) do
          txt = txt .. seg[1]
          hl = hl or seg[2]
        end
        return txt, hl
      end
    end
  end
  return nil
end

local h1_txt, h1_hl = virt_eol_at(0)
check("H1 (row 0) has '…' virt_text", h1_txt == "…", "got " .. tostring(h1_txt))
check(
  "H1 ellipsis hl matches per-level heading title (level 1)",
  h1_hl == "@org.heading.title.1.org",
  "got " .. tostring(h1_hl)
)
check("H2 (row 3, empty body) has NO virt_text", virt_eol_at(3) == nil)
local h3_txt = virt_eol_at(4)
check("H3 (row 4) has '…' virt_text", h3_txt == "…", "got " .. tostring(h3_txt))

contents.leave(b)
local marks_after = vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, {})
check("leave clears virt_text marks too", #marks_after == 0, "got " .. #marks_after)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_ellipsis_test: PASS")
os.exit(0)
