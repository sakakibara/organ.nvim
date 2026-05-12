-- End-to-end coverage for tag right-alignment in folded headings.
-- Folding a heading like `* TODO Foo :work:tag2:` must place the
-- ellipsis right after the title text and right-align the tag
-- block to `config.format.headline.tags_column`.  Two paths to
-- exercise:
--
--   1. Real fold: `emacs_foldtext()` returns segments like
--      `[stars, title, "…", padding, " :work:tag2:"]`.
--   2. CONTENTS view: the heading isn't folded; `place_marks`
--      drops an inline virt_text mark for the ellipsis + padding,
--      and a conceal extmark hiding the whitespace gap between
--      title and tag.
--
-- Edge cases pinned here:
--   - multiple tags in one tag_list (`:work:tag2:`)
--   - negative `tags_column` (offset from window's right edge)
--   - line wider than `tags_column` clamps padding to one space
--
-- Run via: nvim --headless -l tests/fold_foldtext_tag_align_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  scan_on_startup = false,
  watcher = { enabled = false },
  notify = false,
})

local fold = require("organ.fold")
local contents = require("organ.fold.contents")
local cfg = require("organ").config

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function as_string(v)
  if type(v) == "string" then
    return v
  end
  local parts = {}
  for _, seg in ipairs(v) do
    parts[#parts + 1] = seg[1]
  end
  return table.concat(parts)
end

local function with_fold(foldstart, foldend, fn)
  local s, e = vim.v.foldstart, vim.v.foldend
  vim.cmd("let v:foldstart = " .. foldstart)
  vim.cmd("let v:foldend = " .. foldend)
  local ok, out = pcall(fn)
  vim.cmd("let v:foldstart = " .. s)
  vim.cmd("let v:foldend = " .. e)
  if not ok then
    error(out)
  end
  return out
end

-- ── Real-fold path ─────────────────────────────────────────────────
do
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* TODO Foo :work:tag2:",
    "body",
    "more body",
  })
  vim.bo[b].filetype = "org"
  pcall(vim.treesitter.start, b, "org")

  -- Default tags_column = 77.
  local out = with_fold(1, 3, function()
    return fold.foldtext()
  end)
  check("foldtext returns segments", type(out) == "table")
  local s = as_string(out)
  check(
    "ellipsis lands after title 'Foo' (no space before)",
    s:find("Foo…", 1, true) ~= nil,
    "got " .. tostring(s)
  )
  check(
    "rendered ends with the tag block ':work:tag2:'",
    s:sub(-#":work:tag2:") == ":work:tag2:",
    "got " .. tostring(s)
  )
  -- "* TODO Foo" = 10 cols, "…" = 1, ":work:tag2:" = 11.
  -- Padding = 77 - 10 - 1 - 11 = 55.
  -- Total displayed width = 77.
  check(
    "total displayed width = tags_column (77)",
    vim.fn.strdisplaywidth(s) == 77,
    "got width " .. vim.fn.strdisplaywidth(s)
  )

  -- Negative tags_column: offset from window's right edge.
  local saved = cfg.format.headline.tags_column
  cfg.format.headline.tags_column = -10
  local win_width = vim.api.nvim_win_get_width(0)
  local out2 = with_fold(1, 3, function()
    return fold.foldtext()
  end)
  local s2 = as_string(out2)
  check(
    "negative tags_column right-aligns to (win_width - 10 + 1)",
    vim.fn.strdisplaywidth(s2) == win_width - 10 + 1,
    "got width " .. vim.fn.strdisplaywidth(s2) .. " (win=" .. win_width .. ")"
  )
  cfg.format.headline.tags_column = saved

  -- Line wider than tags_column: padding clamps to one space.
  vim.api.nvim_buf_set_lines(b, 0, 1, false, {
    "* TODO " .. string.rep("X", 100) .. " :work:",
  })
  local out3 = with_fold(1, 3, function()
    return fold.foldtext()
  end)
  local s3 = as_string(out3)
  -- The padding segment in `out3` should be exactly one space.
  local ellipsis_idx
  for i, seg in ipairs(out3) do
    if type(seg) == "table" and seg[1] == "…" then
      ellipsis_idx = i
      break
    end
  end
  check("ellipsis present even for over-wide line", ellipsis_idx ~= nil)
  if ellipsis_idx then
    local pad = out3[ellipsis_idx + 1]
    check(
      "padding clamps to one space when line exceeds tags_column",
      type(pad) == "table" and pad[1] == " ",
      "got " .. (type(pad) == "table" and ("%q"):format(pad[1]) or "nil")
    )
  end
  -- And the tag block still sits at the END of the rendered string.
  check(
    "over-wide line still ends with :work:",
    s3:sub(-#":work:") == ":work:",
    "got tail " .. s3:sub(-20)
  )
end

-- ── CONTENTS-view path ─────────────────────────────────────────────
if contents.is_supported() then
  local b = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "* TODO Foo :work:tag2:",
    "body line",
    "more body",
  })
  vim.bo[b].filetype = "org"
  pcall(vim.treesitter.start, b, "org")

  contents.enter(b)
  local NS = vim.api.nvim_get_namespaces().organ_fold_contents
  local marks = vim.api.nvim_buf_get_extmarks(b, NS, 0, -1, { details = true })

  local virt, conceal
  for _, m in ipairs(marks) do
    if m[2] == 0 then
      local d = m[4] or {}
      if d.virt_text then
        virt = m
      elseif d.conceal == "" then
        conceal = m
      end
    end
  end
  check("CONTENTS: tagged headline has virt_text mark", virt ~= nil)
  check("CONTENTS: tagged headline has conceal mark", conceal ~= nil)

  -- Concatenated virt_text + the visible tag bytes after the
  -- concealed gap must read `…<pad>:work:tag2:` with the tags
  -- right-aligned at column 77.
  if virt then
    local d = virt[4] or {}
    local parts = {}
    for _, seg in ipairs(d.virt_text or {}) do
      parts[#parts + 1] = seg[1]
    end
    local txt = table.concat(parts)
    -- "* TODO Foo" = 10 cols; "…" = 1; ":work:tag2:" = 11.
    -- virt_text width = 1 + padding; padding = 77 - 10 - 1 - 11 = 55.
    -- virt_text width should be 56.
    check(
      "CONTENTS: virt_text width = ellipsis + padding = 56",
      vim.fn.strdisplaywidth(txt) == 56,
      "got " .. vim.fn.strdisplaywidth(txt)
    )
  end
  contents.leave(b)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_foldtext_tag_align_test: PASS")
os.exit(0)
