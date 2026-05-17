-- Behavior coverage for the fold-related keymaps installed by
-- ftplugin/core.lua and the underlying organ.fold module:
--
--   <Tab>     fold.cycle      — heading 3-state (collapsed → children
--                               → fully open → collapsed) OR drawer
--                               toggle when cursor is on a drawer line
--   <S-Tab>   fold.cycle_global — global SHOW_ALL → OVERVIEW → CONTENTS
--   zR        Vim builtin     — open every fold
--   zM        Vim builtin     — close every fold (sets foldlevel=0)
--
-- Plus the ftplugin's startup behaviors:
--   close_drawers_on_open    drawers start collapsed under each heading
--   foldenable / foldmethod  set to expr-based on attach
--
-- Run via: nvim --headless -l tests/fold_keymaps_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")


local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- ---------------------------------------------------------------------------
-- Buffer fixture: 3-deep heading tree with a drawer + body lines.
-- `expanded = true` forces foldlevel=99 (showall) post-attach so
-- assertions about body visibility have a known baseline; otherwise
-- the configured `startup.folded` (default `showeverything`) decides.
-- ---------------------------------------------------------------------------
local function fresh_buffer(opts)
  opts = opts or {}
  local tmp = vim.fn.tempname() .. ".org"
  vim.fn.writefile({
    "* H1", -- 1
    "  :PROPERTIES:", -- 2
    "  :ID:       outer", -- 3
    "  :END:", -- 4
    "  body of H1", -- 5
    "** H2-a", -- 6
    "   body of H2-a", -- 7
    "*** H3", -- 8
    "    deep body", -- 9
    "** H2-b", -- 10
    "   body of H2-b", -- 11
    "* H1-second", -- 12
    "  body", -- 13
  }, tmp)
  vim.cmd("edit " .. tmp)
  vim.bo.filetype = "org"
  require("organ.ftplugin.core").attach(0)
  vim.wait(50) -- let scheduled startup-folded + drawer-close fire
  if opts.expanded ~= false then
    vim.wo.foldlevel = 99
    -- Re-close drawers so they stay folded under SHOW_ALL (matches
    -- the close_drawers_on_open default).
    require("organ.fold").close_all_drawers(0)
  end
  return tmp
end

local function cleanup(tmp)
  vim.cmd("bdelete!")
  vim.fn.delete(tmp)
end

-- The user can READ this line's actual text — neither a fold nor a
-- conceal_lines extmark is hiding it.  Use for body lines where the
-- whole point of folding is to hide content; the fold-head
-- placeholder doesn't count as "body shown".  CONTENTS state hides
-- body via conceal_lines extmarks (not folds), so foldclosed alone
-- isn't enough.
local function text_visible(l)
  if vim.fn.foldclosed(l) ~= -1 then
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_get_namespaces()["organ_fold_contents"]
  if not ns then
    return true
  end
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr, ns, { l - 1, 0 }, { l - 1, -1 },
    { details = true, overlap = true }
  )
  for _, m in ipairs(marks) do
    local opts = m[4]
    local end_row = opts.end_row or m[2]
    if m[2] <= (l - 1) and (l - 1) <= end_row and opts.conceal_lines == "" then
      return false
    end
  end
  return true
end

-- The user sees SOMETHING on this screen line — either the original
-- text or, when this line heads its own closed fold, the foldtext
-- placeholder.  Use for heading lines: in OVERVIEW the heading IS
-- the head of a closed fold and shows up as a clickable summary,
-- which is what we want.
local function line_present(l)
  local fc = vim.fn.foldclosed(l)
  return fc == -1 or fc == l
end

-- Default semantics for assertions about heading visibility (each
-- heading is the head of its own fold, so `line_present` matches
-- what the user actually sees on screen).
local visible = line_present

local function visible_count(total)
  local n = 0
  for l = 1, total do
    if visible(l) then
      n = n + 1
    end
  end
  return n
end

-- ---------------------------------------------------------------------------
-- (1) ftplugin attach sets foldmethod=expr + foldenable + foldexpr.
-- ---------------------------------------------------------------------------
do
  local tmp = fresh_buffer()

  check("attach: foldmethod=expr", vim.wo.foldmethod == "expr", vim.wo.foldmethod)
  check("attach: foldenable=true", vim.wo.foldenable == true)
  check(
    "attach: foldexpr routes through organ.fold.foldexpr",
    vim.wo.foldexpr:find("organ.fold", 1, true) ~= nil,
    vim.wo.foldexpr
  )

  cleanup(tmp)
end

-- ---------------------------------------------------------------------------
-- (2) close_drawers_on_open: drawer interior is folded after attach;
--     headings + body are visible.
-- ---------------------------------------------------------------------------
do
  local tmp = fresh_buffer()

  check("attach: heading H1 visible", visible(1))
  check("attach: drawer :ID: line is folded (drawer collapsed)", not visible(3))
  check("attach: body of H1 visible", visible(5))
  check("attach: H2-a heading visible", visible(6))
  check("attach: deep body visible (level=3 body, foldlevel <= 99)", visible(9))

  cleanup(tmp)
end

-- ---------------------------------------------------------------------------
-- (3) <Tab> on a heading line cycles 3 states: collapsed → children
--     → fully open → collapsed.
-- ---------------------------------------------------------------------------
do
  local tmp = fresh_buffer()
  vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on H1
  vim.cmd("silent! normal! zM") -- start fully closed
  check("pre-cycle: H1 subtree collapsed (H2-a hidden)", not visible(6), "H2-a visible despite zM")

  -- First Tab: should expand to show direct children (H2-a, H2-b).
  require("organ.fold").cycle(0, 1)
  check("after 1st Tab on H1: H2-a visible (children opened)", visible(6))
  check(
    "after 1st Tab on H1: H3 still hidden (only direct children)",
    not visible(8),
    "H3 visible too"
  )

  -- Second Tab: fully open everything under H1.
  require("organ.fold").cycle(0, 1)
  check("after 2nd Tab on H1: H3 visible (fully open)", visible(8))
  check("after 2nd Tab on H1: deep body visible", visible(9))

  -- Third Tab: collapse back.
  require("organ.fold").cycle(0, 1)
  check(
    "after 3rd Tab on H1: H2-a hidden (collapsed back)",
    not visible(6),
    "H2-a still visible after 3rd cycle"
  )

  cleanup(tmp)
end

-- ---------------------------------------------------------------------------
-- (4) <Tab> on a drawer line toggles the drawer specifically (no
--     global cycle, no heading cycle).
-- ---------------------------------------------------------------------------
do
  local tmp = fresh_buffer()
  -- H1's PROPERTIES drawer starts collapsed (close_drawers_on_open).
  check("pre: drawer interior folded", not visible(3))
  -- Cursor on the drawer's :PROPERTIES: line and Tab.
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  require("organ.fold").cycle(0, 2)
  check("Tab on :PROPERTIES: opens the drawer", visible(3))
  -- Tab again to re-close.
  require("organ.fold").cycle(0, 2)
  check("Tab on :PROPERTIES: again re-closes the drawer", not visible(3))

  cleanup(tmp)
end

-- ---------------------------------------------------------------------------
-- (5) <S-Tab> cycle_global: SHOW_ALL → OVERVIEW → CONTENTS → SHOW_ALL.
-- ---------------------------------------------------------------------------
do
  -- Bust the build_fold_levels cache so prior tests' levels don't leak.
  require("organ.fold").forget(vim.api.nvim_get_current_buf())
  local tmp = fresh_buffer()

  -- Start in SHOW_ALL (foldlevel=99).
  vim.wo.foldlevel = 99
  require("organ.fold").cycle_global(0)
  -- OVERVIEW: only top-level headings visible.
  check("S-Tab from SHOW_ALL → OVERVIEW: H1 visible", visible(1))
  check("OVERVIEW: H2-a hidden", not visible(6), "foldlevel=" .. vim.wo.foldlevel)
  check("OVERVIEW: H1-second visible", visible(12))

  require("organ.fold").cycle_global(0)
  vim.cmd("silent! normal! zx") -- recompute folds; headless skips auto-recompute
  -- CONTENTS: every heading visible, every body line hidden via the
  -- conceal_lines extmark layer.  foldlevel stays at 99 (no fold
  -- closing); body is hidden purely via extmarks.
  check("S-Tab from OVERVIEW → CONTENTS: H1 visible", visible(1))
  check("CONTENTS: H2-a visible", visible(6))
  check("CONTENTS: H3 visible", visible(8))
  check("CONTENTS: body of H1 hidden (text not shown)", not text_visible(5))
  check("CONTENTS: body of H2-a hidden (text not shown)", not text_visible(7))
  check("CONTENTS: deep body hidden (text not shown)", not text_visible(9))

  require("organ.fold").cycle_global(0)
  -- SHOW_ALL: everything except drawers (close_drawers_on_open).
  check("S-Tab from CONTENTS → SHOW_ALL: body of H2-a visible", visible(7))
  check("SHOW_ALL: deep body visible", visible(9))

  cleanup(tmp)
end

-- ---------------------------------------------------------------------------
-- (6) zR opens every fold (Vim builtin) including drawers.
-- ---------------------------------------------------------------------------
do
  local tmp = fresh_buffer()
  vim.cmd("silent! normal! zM") -- close all
  vim.cmd("silent! normal! zR")
  local total = vim.api.nvim_buf_line_count(0)
  check(
    "zR: every line visible (no closed folds)",
    visible_count(total) == total,
    string.format("%d/%d visible (foldlevel=%d)", visible_count(total), total, vim.wo.foldlevel)
  )
  check("zR: drawer interior visible too", visible(3))
  cleanup(tmp)
end

-- ---------------------------------------------------------------------------
-- (7) zM closes every fold (foldlevel=0).
-- ---------------------------------------------------------------------------
do
  local tmp = fresh_buffer()
  vim.cmd("silent! normal! zM")
  -- foldlevel goes to 0 with zM.  All non-zero-level lines fold up.
  check("zM: H2-a hidden", not visible(6))
  check("zM: deep body hidden", not visible(9))
  -- Top-level headings have foldlevel 1 → hidden when foldlevel=0;
  -- but we still expect H1 to be reachable as the FIRST line of its fold.
  cleanup(tmp)
end

-- ---------------------------------------------------------------------------
-- (8) `keymaps = false` disables fold bindings entirely.
-- ---------------------------------------------------------------------------
do
  -- Rebuild buffer with keymaps disabled.
  local tmp = vim.fn.tempname() .. ".org"
  vim.fn.writefile({ "* H1", "* H2" }, tmp)
  require("organ").config.fold.keymaps = false
  vim.cmd("edit " .. tmp)
  vim.bo.filetype = "org"
  require("organ.ftplugin.core").attach(0)
  vim.wait(20)

  local kmaps = vim.api.nvim_buf_get_keymap(0, "n")
  local has_tab = false
  local has_stab = false
  for _, m in ipairs(kmaps) do
    if m.lhs == "<Tab>" then
      has_tab = true
    end
    if m.lhs == "<S-Tab>" then
      has_stab = true
    end
  end
  check("keymaps=false: <Tab> not installed", not has_tab)
  check("keymaps=false: <S-Tab> not installed", not has_stab)
  -- Restore default.
  require("organ").config.fold.keymaps = { cycle = "<Tab>", cycle_global = "<S-Tab>" }
  vim.cmd("bdelete!")
  vim.fn.delete(tmp)
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("fold_keymaps_test: PASS")
