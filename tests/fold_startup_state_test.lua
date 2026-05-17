-- `#+STARTUP:` (and the global `startup.folded` config) goes through
-- the same organ.fold.apply_* helpers as <S-Tab> cycle_global.  Both
-- paths used to inline their own foldlevel / extmark logic and
-- drifted: `#+STARTUP: overview` used to set foldlevel=1 (showing L=1
-- AND L=2 headings) while cycle_global's OVERVIEW set foldlevel=0
-- (only L=1).  Result: opening with `overview` landed in a state
-- S-Tab could never cycle back to.  This test pins each
-- `#+STARTUP:` directive against the same observable post-conditions
-- that cycle_global produces for that state.
--
-- Run via: nvim --headless -l tests/fold_startup_state_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

-- Open a fresh org buffer in its own window with the given
-- `#+STARTUP:` directive and let the scheduled apply_* helper run.
-- Returns (winid, bufnr).
local function open_with_startup(directive)
  require("organ").setup({
    db_path = vim.fn.tempname() .. ".db",
    notify = false,
    scan_on_startup = false,
    watcher = { enabled = false },
  })
  local tmp = vim.fn.tempname() .. ".org"
  vim.fn.writefile({
    "#+TITLE: Test",
    "#+STARTUP: " .. directive,
    "",
    "* L1 alpha",
    "body of alpha",
    "",
    "** L2 child",
    "",
    "*** L3 grandchild",
    "deep body",
    "",
    "* L1 beta",
    "body of beta",
  }, tmp)
  vim.cmd("edit " .. tmp)
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  -- nvim --headless -u NONE doesn't run filetype.lua, so :edit on a
  -- .org path doesn't fire FileType.  Set it manually so the ftplugin
  -- (and its scheduled apply_global_state) runs.
  if vim.bo[bufnr].filetype ~= "org" then
    vim.bo[bufnr].filetype = "org"
  end
  vim.cmd("normal! zx") -- ensure foldexpr ran
  vim.wait(200) -- drain scheduled apply_*
  return winid, bufnr
end

-- A line counts as "visible" when it isn't folded into a closed fold
-- AND isn't covered by a `conceal_lines` extmark.  CONTENTS state
-- hides body via extmarks (not folds), so foldclosed alone misses it.
local function visible(bufnr, lnum)
  if vim.fn.foldclosed(lnum) > 0 and vim.fn.foldclosed(lnum) ~= lnum then
    return false
  end
  local ns = vim.api.nvim_get_namespaces()["organ_fold_contents"]
  if not ns then
    return true
  end
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, ns, { lnum - 1, 0 }, { lnum - 1, -1 },
    { details = true, overlap = true }
  )
  for _, m in ipairs(marks) do
    local opts = m[4]
    local end_row = opts.end_row or m[2]
    if m[2] <= (lnum - 1) and (lnum - 1) <= end_row and opts.conceal_lines == "" then
      return false
    end
  end
  return true
end

-- Line layout (1-indexed):
--   1  #+TITLE
--   2  #+STARTUP
--   3  <blank>
--   4  * L1 alpha
--   5  body of alpha
--   6  <blank>
--   7  ** L2 child
--   8  <blank>
--   9  *** L3 grandchild
--   10 deep body
--   11 <blank>
--   12 * L1 beta
--   13 body of beta

-- #+STARTUP: overview --------------------------------------------------------
do
  local winid, bufnr = open_with_startup("overview")
  -- OVERVIEW: only L=1 headings visible (collapsed into foldtext).
  -- Sub-headings (L=2, L=3) and body collapse into the L=1 fold.
  check(
    "overview: L=1 headings visible",
    visible(bufnr, 4) and visible(bufnr, 12),
    string.format("L4=%s L12=%s", tostring(visible(bufnr, 4)), tostring(visible(bufnr, 12)))
  )
  check(
    "overview: L=2 heading hidden",
    not visible(bufnr, 7),
    "L7 visible (should be inside L=1 closed fold)"
  )
  check(
    "overview: L=3 heading hidden",
    not visible(bufnr, 9),
    "L9 visible (should be inside L=1 closed fold)"
  )
  check(
    "overview: body hidden",
    not visible(bufnr, 5),
    "L5 (body) visible"
  )
  -- Position cycle_global at OVERVIEW.  cycle_global cycles
  -- show_all -> overview -> content -> show_all, so detect_global_state
  -- must already report "overview" here for S-Tab to land at "content"
  -- next.
  local fold = require("organ.fold")
  check(
    "overview: detect_global_state == 'overview'",
    fold.detect_global_state(winid, bufnr) == "overview",
    "got " .. fold.detect_global_state(winid, bufnr)
  )
end

-- #+STARTUP: content ---------------------------------------------------------
do
  local winid, bufnr = open_with_startup("content")
  -- CONTENTS: every heading visible (L=1, L=2, L=3), every body line
  -- hidden via the `conceal_lines` extmark layer.
  check(
    "content: L=1 heading visible",
    visible(bufnr, 4) and visible(bufnr, 12),
    "L=1 hidden"
  )
  check("content: L=2 heading visible", visible(bufnr, 7), "L7 hidden")
  check("content: L=3 heading visible", visible(bufnr, 9), "L9 hidden")
  check(
    "content: body of L=1 hidden",
    not visible(bufnr, 5),
    "L5 (body) visible — extmark layer not active?"
  )
  check(
    "content: deep body hidden",
    not visible(bufnr, 10),
    "L10 visible"
  )
  local fold = require("organ.fold")
  check(
    "content: detect_global_state == 'content'",
    fold.detect_global_state(winid, bufnr) == "content",
    "got " .. fold.detect_global_state(winid, bufnr)
  )
end

-- #+STARTUP: showall ---------------------------------------------------------
do
  local _, bufnr = open_with_startup("showall")
  -- SHOW_ALL: every heading + body visible; drawers stay closed
  -- (none in this fixture so just check headings + body).
  check("showall: L=1 heading visible", visible(bufnr, 4))
  check("showall: L=2 heading visible", visible(bufnr, 7))
  check("showall: L=3 heading visible", visible(bufnr, 9))
  check("showall: body of L=1 visible", visible(bufnr, 5))
  check("showall: deep body visible", visible(bufnr, 10))
end

-- #+STARTUP: showeverything --------------------------------------------------
do
  local _, bufnr = open_with_startup("showeverything")
  -- SHOW_EVERYTHING: same as SHOW_ALL for this fixture (no drawers
  -- to differ on).
  check("showeverything: L=1 heading visible", visible(bufnr, 4))
  check("showeverything: L=2 heading visible", visible(bufnr, 7))
  check("showeverything: body visible", visible(bufnr, 5))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_startup_state_test: PASS")
