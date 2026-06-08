-- Regression: the decoration redraw path must parse only the visible
-- range, not the whole org_inline injection forest.  parser:parse(true)
-- on a long file materialises hundreds of injection trees and costs
-- 130-500ms+ synchronously per cold / first-post-edit redraw -- the
-- freeze this guards against.  Range parsing keeps cost bounded by the
-- viewport regardless of file size.
--
-- Bounds are both structural (injection-tree count, not flaky) and
-- wall-clock (generous, to also catch a silent perf regression).
--
-- Run via: nvim --headless -l tests/decoration_parse_range_bounded_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  emphasis = { enabled = true },
})
require("organ.conceal")

local decoration = require("organ.decoration")
local profile = require("organ.profile")

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and ("\n     " .. detail) or ""))
  end
end

local LINES = 8000
local VIEWPORT = 50 -- rows
local TREE_CEILING = 40 -- range parse yields ~2; parse(true) yields ~320
local MS_BUDGET = 80 -- range parse ~1-2ms; parse(true) is 130-500ms on this size

local sentence = "Some *bold* and /italic/ and [[https://x.com][link]] and <2026-06-08 Mon> stamp. "
local function build(n)
  local l = {}
  while #l < n do
    l[#l + 1] = (#l % 50 == 0) and ("* H " .. #l) or sentence:rep(3)
  end
  return l
end

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, build(LINES))
local winid = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(winid, bufnr)
vim.wo[winid].conceallevel = 2
decoration.attach(bufnr)

profile.frame_enabled = true
profile._records = {}

-- Cold open == first redraw == first dispatch_on_win for the viewport.
decoration._dispatch_on_win(0, winid, bufnr, 0, VIEWPORT - 1)

local function parse_max_ms()
  local r = profile._records["frame.parse"]
  return r and r.max_ms or 0
end

check(
  string.format("cold-open parse under %dms (was 130-500ms with parse(true))", MS_BUDGET),
  parse_max_ms() < MS_BUDGET,
  string.format("cold-open parse = %.1fms", parse_max_ms())
)

-- Structural: only the viewport's injection trees should be materialised.
local function inline_tree_count()
  local _, parser = pcall(vim.treesitter.get_parser, bufnr, "org")
  local n = 0
  for _, child in pairs(parser:children()) do
    if child:lang() == "org_inline" then
      n = n + #(child:trees() or {})
    end
  end
  return n
end

check(
  string.format(
    "injection trees materialised <= %d (whole-forest would be ~%d)",
    TREE_CEILING,
    LINES / 50
  ),
  inline_tree_count() <= TREE_CEILING,
  "materialised " .. inline_tree_count() .. " org_inline trees"
)

-- Sustained typing: every keystroke's reparse stays bounded.
local worst = 0
for _ = 1, 12 do
  vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { "z" })
  profile._records["frame.parse"] = nil
  decoration._dispatch_on_win(0, winid, bufnr, 0, VIEWPORT - 1)
  worst = math.max(worst, parse_max_ms())
end
check(
  string.format("worst per-keystroke reparse under %dms", MS_BUDGET),
  worst < MS_BUDGET,
  string.format("worst keystroke reparse = %.1fms", worst)
)

profile.frame_enabled = false

-- Coverage: range parsing must still let conceal place its marks.
local providers = decoration._providers()
require("organ.conceal")._apply(bufnr)
local marks = vim.api.nvim_buf_get_extmarks(bufnr, providers.conceal.ns, 0, -1, {})
check("conceal still emits marks under range parsing", #marks > 0, "#marks = " .. #marks)

if fails > 0 then
  error(fails .. " check(s) failed")
end
print("\nAll checks passed.")
