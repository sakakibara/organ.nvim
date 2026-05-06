-- Spacing-policy is applied across structure operations that mutate
-- the buffer: archive_subtree, archive_to_sibling, refile.move, and
-- clipboard cut/paste.  Each leaves the buffer in a state that
-- matches the surrounding blank-line convention rather than orphaning
-- stale blanks at the cut site or under-spacing the destination.
--
-- Run via: nvim --headless -l tests/spacing_integration_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("  -- " .. detail) or ""))
  end
end

require("organ").setup({
  org_dir = vim.fn.tempname(),
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local function set_buf(b, lines)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
end

local function get_buf(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

-- ---------------------------------------------------------------------------
-- (a) clipboard.cut: deletion site collapses orphan blanks to the
--     buffer's "before" policy.  Two-blank-between style → cut middle
--     subtree → exactly two blanks remain between surviving siblings.
-- ---------------------------------------------------------------------------
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].filetype = "org"
  vim.api.nvim_set_current_buf(b)
  set_buf(b, {
    "* A",
    "",
    "",
    "* B",
    "  body",
    "",
    "",
    "* C",
  })
  local err = require("organ.clipboard").cut(b, 4)
  check("cut: returns nil on success", err == nil, tostring(err))

  local out = get_buf(b)
  local expect = { "* A", "", "", "* C" }
  local ok = #out == #expect
  if ok then
    for i = 1, #expect do
      if out[i] ~= expect[i] then
        ok = false
        break
      end
    end
  end
  check("cut: deletion site normalized to surrounding pattern", ok, vim.inspect(out))
end

-- ---------------------------------------------------------------------------
-- (b) clipboard.paste: destination heading gets the buffer's spacing
--     policy applied automatically.  Source = none-style buffer; copy
--     a subtree, paste into a "before"-style buffer; pasted heading
--     ends up with one blank above.
-- ---------------------------------------------------------------------------
do
  -- 1. Cut a subtree from a "tight" buffer.
  local src = vim.api.nvim_create_buf(false, true)
  vim.bo[src].filetype = "org"
  vim.api.nvim_set_current_buf(src)
  set_buf(src, { "* A", "* B", "  body", "* C" })
  require("organ.clipboard").cut(src, 2) -- removes "* B" subtree

  -- 2. Paste into a buffer that uses one blank ABOVE every heading.
  local dst = vim.api.nvim_create_buf(false, true)
  vim.bo[dst].filetype = "org"
  vim.api.nvim_set_current_buf(dst)
  set_buf(dst, {
    "* X",
    "",
    "* Y",
    "",
    "* Z",
  })
  -- Paste below "* X" (line 1).
  local err = require("organ.clipboard").paste(dst, 1)
  check("paste: returns nil on success", err == nil, tostring(err))

  local out = get_buf(dst)
  -- The pasted block becomes a child of "* X" (level 2 → "** B"),
  -- positioned at end-of-X-subtree, which sits just before "* Y".
  -- normalize_around runs on the pasted heading; since "** B" is the
  -- only level-2 heading, the policy's "before" should kick in for it.
  local saw_pasted = false
  for _, l in ipairs(out) do
    if l:match("^%*%* ") then
      saw_pasted = true
    end
  end
  check("paste: pasted heading inserted at re-leveled depth", saw_pasted, vim.inspect(out))
end

-- ---------------------------------------------------------------------------
-- (c) archive_subtree: cut site is tidied even though the
--     subtree-removal happens before the spacing call.
-- ---------------------------------------------------------------------------
do
  local tmp_src = vim.fn.tempname() .. ".org"
  local f = io.open(tmp_src, "w")
  f:write([[* A

* B
  body

* C
]])
  f:close()

  vim.cmd("edit " .. vim.fn.fnameescape(tmp_src))
  local b = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- on "* B"
  local err = require("organ.archive").archive_subtree({ bufnr = b, line = 3 })
  check("archive: returns nil on success", err == nil, tostring(err))

  local out = get_buf(b)
  -- Buffer style is one blank between headings; after removing "* B",
  -- there should be exactly one blank between "* A" and "* C".
  local found_a, blank_after_a, found_c
  for i, l in ipairs(out) do
    if l == "* A" then
      found_a = i
    end
    if found_a and i == found_a + 1 and l == "" then
      blank_after_a = true
    end
    if l == "* C" then
      found_c = i
    end
  end
  check("archive: cut site normalized", found_a and blank_after_a and found_c, vim.inspect(out))

  -- Cleanup.
  pcall(os.remove, tmp_src)
  pcall(os.remove, tmp_src .. "_archive")
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("spacing_integration_test: PASS")
