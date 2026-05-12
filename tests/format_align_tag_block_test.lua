-- Coverage for `format.align_tag_block` and its underlying resolver
-- `format._resolve_tags_column`.  Pins the polymorphic shapes the
-- config option accepts (integer, string, function, false, 0) and
-- verifies the alignment math for each.
--
-- Run via: nvim --headless -l tests/format_align_tag_block_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local format = require("organ.format")
local organ = require("organ")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- Test the resolver directly first (no buffer state needed for
-- numeric / function / false / 0 cases).

-- nil / false  -> nil (no alignment)
check("resolver: nil -> nil", format._resolve_tags_column(nil) == nil)
check("resolver: false -> nil", format._resolve_tags_column(false) == nil)

-- 0 -> flush
do
  local r = format._resolve_tags_column(0)
  check("resolver: 0 -> { kind = 'flush' }", r and r.kind == "flush")
end

-- Positive integer -> left
do
  local r = format._resolve_tags_column(42)
  check(
    "resolver: 42 -> { kind = 'left', column = 42 }",
    r and r.kind == "left" and r.column == 42,
    vim.inspect(r)
  )
end

-- Negative integer -> right
do
  local r = format._resolve_tags_column(-77)
  check(
    "resolver: -77 -> { kind = 'right', column = 77 }",
    r and r.kind == "right" and r.column == 77,
    vim.inspect(r)
  )
end

-- "textwidth" — set vim.bo.textwidth on the current buffer to pin it.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 72
  local r = format._resolve_tags_column("textwidth", b)
  check(
    "resolver: 'textwidth' reads vim.bo[bufnr].textwidth (72)",
    r and r.kind == "right" and r.column == 72,
    vim.inspect(r)
  )
  -- Fallback to 80 when textwidth is 0/unset.
  vim.bo[b].textwidth = 0
  local r2 = format._resolve_tags_column("textwidth", b)
  check(
    "resolver: 'textwidth' falls back to 80 when textwidth is 0",
    r2 and r2.kind == "right" and r2.column == 80,
    vim.inspect(r2)
  )
end

-- "textwidth+N" / "textwidth-N"
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 72
  local r1 = format._resolve_tags_column("textwidth-3", b)
  check(
    "resolver: 'textwidth-3' with tw=72 -> right edge at 69",
    r1 and r1.kind == "right" and r1.column == 69,
    vim.inspect(r1)
  )
  local r2 = format._resolve_tags_column("textwidth+5", b)
  check(
    "resolver: 'textwidth+5' with tw=72 -> right edge at 77",
    r2 and r2.kind == "right" and r2.column == 77,
    vim.inspect(r2)
  )
  local r3 = format._resolve_tags_column("textwidth+0", b)
  check(
    "resolver: 'textwidth+0' equivalent to 'textwidth'",
    r3 and r3.kind == "right" and r3.column == 72,
    vim.inspect(r3)
  )
end

-- "winwidth": use current window (whatever headless gives us).
do
  local w = vim.api.nvim_get_current_win()
  local ww = vim.api.nvim_win_get_width(w)
  local r = format._resolve_tags_column("winwidth", nil, w)
  check(
    "resolver: 'winwidth' reads nvim_win_get_width",
    r and r.kind == "right" and r.column == ww,
    vim.inspect(r) .. " (win=" .. ww .. ")"
  )
  local r2 = format._resolve_tags_column("winwidth-3", nil, w)
  check(
    "resolver: 'winwidth-3' subtracts 3 from window width",
    r2 and r2.kind == "right" and r2.column == ww - 3,
    vim.inspect(r2)
  )
end

-- Function returning a number -> recursively resolved.
do
  local r = format._resolve_tags_column(function()
    return 50
  end)
  check(
    "resolver: function returning 50 -> { kind='left', column=50 }",
    r and r.kind == "left" and r.column == 50,
    vim.inspect(r)
  )
end

-- Function returning a string -> recursively resolved.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 60
  local r = format._resolve_tags_column(function()
    return "textwidth-5"
  end, b)
  check(
    "resolver: function returning 'textwidth-5' -> right edge at 55",
    r and r.kind == "right" and r.column == 55,
    vim.inspect(r)
  )
end

-- Function returning false -> nil (no alignment).
do
  local r = format._resolve_tags_column(function()
    return false
  end)
  check("resolver: function returning false -> nil", r == nil, vim.inspect(r))
end

-- Function returning 0 -> flush.
do
  local r = format._resolve_tags_column(function()
    return 0
  end)
  check("resolver: function returning 0 -> flush", r and r.kind == "flush", vim.inspect(r))
end

-- Function that raises -> nil (no alignment, caller falls back).
do
  local r = format._resolve_tags_column(function()
    error("boom")
  end)
  check("resolver: function that raises -> nil", r == nil, vim.inspect(r))
end

-- String-form parser edge cases.
do
  -- Bare "textwidth" already covered above.  Reject malformed forms:
  check(
    "resolver: 'textwidth+' rejected (sign without number)",
    format._resolve_tags_column("textwidth+") == nil
  )
  check(
    "resolver: 'textwidth-' rejected (sign without number)",
    format._resolve_tags_column("textwidth-") == nil
  )
  check(
    "resolver: 'textwidth+abc' rejected (non-numeric suffix)",
    format._resolve_tags_column("textwidth+abc") == nil
  )
  -- Unknown base names:
  check("resolver: 'foo' rejected (unknown base)", format._resolve_tags_column("foo") == nil)
  check("resolver: 'foo+3' rejected (unknown base)", format._resolve_tags_column("foo+3") == nil)
  -- "textwidth-0" parses to right edge at textwidth (offset 0).
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 65
  local r = format._resolve_tags_column("textwidth-0", b)
  check(
    "resolver: 'textwidth-0' -> right edge at textwidth",
    r and r.kind == "right" and r.column == 65,
    vim.inspect(r)
  )
end

-- Column clamps to >= 1 when textwidth + offset would go negative.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 5
  local r = format._resolve_tags_column("textwidth-100", b)
  check(
    "resolver: clamps column to >= 1 when offset goes negative",
    r and r.kind == "right" and r.column == 1,
    vim.inspect(r)
  )
end

-- Now align_tag_block end-to-end.

-- Empty / nil tags -> returns left unchanged.
check("align: nil tags returns left unchanged", format.align_tag_block("* H", nil) == "* H")
check("align: '' tags returns left unchanged", format.align_tag_block("* H", "") == "* H")

-- Positive number = LEFT edge at column N.
do
  -- "* H" = 3 cols.  tags_column = 10 -> LEFT edge at col 10.
  -- Pad = 10 - 3 = 7.
  local got = format.align_tag_block("* H", ":t:", { tags_column = 10 })
  local want = "* H" .. string.rep(" ", 7) .. ":t:"
  check(
    "align: positive integer = LEFT edge",
    got == want,
    "got [" .. got .. "] want [" .. want .. "]"
  )
end

-- Negative number = RIGHT edge at column |N|.
do
  -- "* H" = 3.  ":t:" = 3.  tags_column = -10 -> right edge at 10.
  -- Left edge at 10 - 3 = 7.  Pad = 7 - 3 = 4.
  local got = format.align_tag_block("* H", ":t:", { tags_column = -10 })
  local want = "* H" .. string.rep(" ", 4) .. ":t:"
  check(
    "align: negative integer = RIGHT edge",
    got == want,
    "got [" .. got .. "] want [" .. want .. "]"
  )
end

-- 0 -> one space.
do
  local got = format.align_tag_block("* H", ":t:", { tags_column = 0 })
  check("align: 0 -> one space", got == "* H :t:", "got [" .. got .. "]")
end

-- false -> no alignment, fall back to single space.
do
  local got = format.align_tag_block("* H", ":t:", { tags_column = false })
  check("align: false -> single space (no alignment)", got == "* H :t:", "got [" .. got .. "]")
end

-- "textwidth": pass bufnr in opts so the resolver reads the right buffer.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 20
  -- "* H" = 3, ":t:" = 3, right edge at 20 -> left edge at 17 -> pad 14.
  local got = format.align_tag_block("* H", ":t:", { tags_column = "textwidth", bufnr = b })
  local want = "* H" .. string.rep(" ", 14) .. ":t:"
  check('align: "textwidth" with tw=20 -> right edge at 20', got == want, "got [" .. got .. "]")
end

-- "textwidth-3" / "textwidth+5".
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 20
  -- "textwidth-3" -> right edge at 17 -> pad = 17 - 3 - 3 = 11.
  local got1 = format.align_tag_block("* H", ":t:", { tags_column = "textwidth-3", bufnr = b })
  local want1 = "* H" .. string.rep(" ", 11) .. ":t:"
  check('align: "textwidth-3"', got1 == want1, "got [" .. got1 .. "]")
  -- "textwidth+5" -> right edge at 25 -> pad = 25 - 3 - 3 = 19.
  local got2 = format.align_tag_block("* H", ":t:", { tags_column = "textwidth+5", bufnr = b })
  local want2 = "* H" .. string.rep(" ", 19) .. ":t:"
  check('align: "textwidth+5"', got2 == want2, "got [" .. got2 .. "]")
end

-- "winwidth": use current window.
do
  local w = vim.api.nvim_get_current_win()
  local ww = vim.api.nvim_win_get_width(w)
  -- "* H" = 3, ":t:" = 3, right edge at ww -> pad = ww - 3 - 3 = ww - 6.
  local got = format.align_tag_block("* H", ":t:", { tags_column = "winwidth", winid = w })
  local want = "* H" .. string.rep(" ", ww - 6) .. ":t:"
  check('align: "winwidth"', got == want, "got [" .. got .. "]")
end

-- Function returning a number.
do
  local got = format.align_tag_block("* H", ":t:", {
    tags_column = function()
      return 20
    end,
  })
  -- 20 = LEFT edge -> pad = 20 - 3 = 17.
  local want = "* H" .. string.rep(" ", 17) .. ":t:"
  check("align: function returning number 20 (LEFT edge)", got == want, "got [" .. got .. "]")
end

-- Function returning a string.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].textwidth = 30
  local got = format.align_tag_block("* H", ":t:", {
    tags_column = function()
      return "textwidth-5"
    end,
    bufnr = b,
  })
  -- textwidth-5 = 25, right edge -> pad = 25 - 3 - 3 = 19.
  local want = "* H" .. string.rep(" ", 19) .. ":t:"
  check("align: function returning 'textwidth-5'", got == want, "got [" .. got .. "]")
end

-- Function returning false -> single space.
do
  local got = format.align_tag_block("* H", ":t:", {
    tags_column = function()
      return false
    end,
  })
  check("align: function returning false -> single space", got == "* H :t:", "got [" .. got .. "]")
end

-- Long line clamps to single-space pad.
do
  local left = "* " .. string.rep("x", 80)
  local got = format.align_tag_block(left, ":t:", { tags_column = -10 })
  check(
    "align: line wider than column clamps to single-space pad",
    got == left .. " :t:",
    "got [" .. got .. "]"
  )
end

-- Default (config-driven) path: nil opts falls through to config.
-- Config default is "textwidth".  Pin via config and verify.
do
  local saved = organ.config.format.headline.tags_column
  organ.config.format.headline.tags_column = -50
  local got = format.align_tag_block("* H", ":t:", {})
  -- right edge at 50, ":t:" = 3, left edge = 47, pad = 47 - 3 = 44.
  local want = "* H" .. string.rep(" ", 44) .. ":t:"
  check("align: nil opts.tags_column reads config (-50)", got == want, "got [" .. got .. "]")
  organ.config.format.headline.tags_column = saved
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("format_align_tag_block_test: PASS")
os.exit(0)
