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
  -- Pin tag right edge at 77 so the column assertions below stay
  -- independent of textwidth / window width (production default
  -- "textwidth" would depend on the buffer's textwidth option).
  format = { headline = { tags_column = -77 } },
})

local contents = require("organ.fold.contents")

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
      if d.virt_text and (d.virt_text_pos == "eol" or d.virt_text_pos == "inline") then
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

-- Tagged heading: the ellipsis must land BETWEEN the title text
-- and the tag block, with padding spaces that right-align the tag
-- block to `config.format.heading.tags_column` (default 77).  The
-- raw whitespace between title and tag is hidden by a separate
-- conceal extmark so it doesn't push the tags past the column.
local b2 = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(b2)
vim.api.nvim_buf_set_lines(b2, 0, -1, false, {
  "* TODO Foo :work:", -- 1
  "body line", -- 2
  "more body", -- 3
})
vim.bo[b2].filetype = "org"
pcall(vim.treesitter.start, b2, "org")

contents.enter(b2)

local marks2 = vim.api.nvim_buf_get_extmarks(b2, NS, 0, -1, { details = true })

-- The headline row should carry two extmarks: one inline virt_text
-- (ellipsis + padding) and one conceal extmark covering the
-- whitespace gap between title and tag.
local virt_mark, conceal_mark
for _, m in ipairs(marks2) do
  if m[2] == 0 then
    local d = m[4] or {}
    if d.virt_text then
      virt_mark = m
    elseif d.conceal == "" then
      conceal_mark = m
    end
  end
end

check("tagged headline has inline virt_text mark", virt_mark ~= nil)
check("tagged headline has a conceal mark over whitespace gap", conceal_mark ~= nil)

-- The buffer line is `* TODO Foo :work:` (0-indexed bytes 0..16).
-- Title ends at byte 10 (one past `Foo`'s `o`); tag_list starts
-- at byte 11 (`:`).  The virt_text mark sits at col 10 (title
-- end); the conceal mark covers cols 10..11.
if virt_mark then
  check(
    "virt_text mark sits at title-end col (10)",
    virt_mark[3] == 10,
    "got col " .. tostring(virt_mark[3])
  )
  local d = virt_mark[4] or {}
  local parts = {}
  for _, seg in ipairs(d.virt_text or {}) do
    parts[#parts + 1] = seg[1]
  end
  local txt = table.concat(parts)
  check("virt_text starts with ellipsis", txt:sub(1, #"…") == "…", "got " .. tostring(txt))
  -- The remainder of virt_text is padding spaces.  With default
  -- tags_column = 77, title width = 10 ("* TODO Foo"), ellipsis = 1,
  -- tag width = 6 (":work:"), padding = 77 - 10 - 1 - 6 = 60.
  local pad_part = txt:sub(#"…" + 1)
  check(
    "virt_text padding is all spaces",
    pad_part:match("^%s+$") ~= nil,
    "got " .. ("%q"):format(pad_part)
  )
  check(
    "virt_text padding width right-aligns tags to column 77",
    vim.fn.strdisplaywidth(pad_part) == 60,
    "got padding width " .. vim.fn.strdisplaywidth(pad_part)
  )
end
if conceal_mark then
  check(
    "conceal mark starts at title-end col (10)",
    conceal_mark[3] == 10,
    "got col " .. tostring(conceal_mark[3])
  )
  local d = conceal_mark[4] or {}
  check(
    "conceal mark ends at tag-start col (11)",
    d.end_col == 11,
    "got end_col " .. tostring(d.end_col)
  )
end

contents.leave(b2)

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_contents_ellipsis_test: PASS")
os.exit(0)
