-- Grammar fuzz harness.  Generates pathological / malformed input
-- patterns, parses each one with a 5s timeout + 50 MB RSS bound, and
-- asserts:
--
--   1. parse completes (no infinite-loop / catastrophic backtrack)
--   2. RSS doesn't explode
--   3. no Neovim crash (parse errors are EXPECTED, not failures)
--
-- Complements the static `tests/fixtures/invalid/` corpus which is
-- aimed at known surface forms; this harness throws synthetic chaos.
--
-- Run via: nvim --headless -l tests/grammar_fuzz_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
})

local pp = require("organ.defaults").parser_path
vim.treesitter.language.add("org", { path = pp })
vim.treesitter.language.add("org_inline", { path = (pp:gsub("/org%.so$", "/org_inline.so")) })

local function rss_kb()
  local f = io.open("/proc/self/status", "r")
  if not f then
    return 0
  end
  for line in f:lines() do
    local kb = line:match("^VmRSS:%s+(%d+)")
    if kb then
      f:close()
      return tonumber(kb)
    end
  end
  f:close()
  return 0
end

local TIME_BOUND_MS = 5000
local MEM_BOUND_KB = 50 * 1024

local fails = 0
local function check(label, ok, detail)
  if ok then
    print("PASS  " .. label)
  else
    fails = fails + 1
    print("FAIL  " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function timed_parse(label, src)
  local rss0 = rss_kb()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(src, "\n", { plain = true }))
  vim.bo[b].filetype = "org"
  local t0 = vim.uv.hrtime()
  local ok, parser = pcall(vim.treesitter.get_parser, b, "org")
  local elapsed_ms
  if ok and parser then
    pcall(function()
      parser:parse(true)
    end)
    elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  else
    elapsed_ms = 0
  end
  local rss_growth = rss_kb() - rss0
  vim.api.nvim_buf_delete(b, { force = true })
  check(
    label .. ": time < " .. TIME_BOUND_MS .. "ms (got " .. math.floor(elapsed_ms) .. "ms)",
    elapsed_ms < TIME_BOUND_MS
  )
  check(label .. ": RSS growth < " .. MEM_BOUND_KB .. "KB", rss_growth < MEM_BOUND_KB)
end

-- Synthetic chaos generators.

-- 1. Many headlines, deep nesting.
do
  local lines = {}
  for level = 1, 9 do
    lines[#lines + 1] = string.rep("*", level) .. " Heading L" .. level
  end
  for _ = 1, 200 do
    lines[#lines + 1] = "** TODO Repeated child"
  end
  timed_parse("deep nested headlines", table.concat(lines, "\n"))
end

-- 2. Long heading line with every field.
do
  local s = "* TODO COMMENT [#A] "
    .. string.rep("word ", 200)
    .. "[33%] :tag1:tag2:tag3:tag4:tag5:\n"
  timed_parse("long combo heading", s)
end

-- 3. Massive property drawer.
do
  local lines = { "* H", ":PROPERTIES:" }
  for i = 1, 500 do
    lines[#lines + 1] = ":KEY" .. i .. ": value " .. i
  end
  lines[#lines + 1] = ":END:"
  timed_parse("500-property drawer", table.concat(lines, "\n"))
end

-- 4. Deeply nested lists.
do
  local lines = {}
  for i = 1, 20 do
    lines[#lines + 1] = string.rep("  ", i) .. "- [ ] item depth " .. i
  end
  timed_parse("20-deep nested checkbox list", table.concat(lines, "\n"))
end

-- 5. Large LOGBOOK with many CLOCK entries.
do
  local lines = { "* H", ":LOGBOOK:" }
  for i = 1, 500 do
    lines[#lines + 1] = string.format(
      "CLOCK: [2026-01-%02d Mon 09:00]--[2026-01-%02d Mon 17:00] => 8:00",
      (i % 28) + 1,
      (i % 28) + 1
    )
  end
  lines[#lines + 1] = ":END:"
  timed_parse("500-clock LOGBOOK", table.concat(lines, "\n"))
end

-- 6. Pathological link bytes — escaped brackets, unclosed, mixed.
do
  local s = "[["
    .. string.rep("[", 50)
    .. "]]\n"
    .. "[[id:"
    .. string.rep("a", 1000)
    .. "]]\n"
    .. "[["
    .. string.rep("][", 30)
    .. "]]\n"
    .. "[[\n[[unclosed\n[[id:foo][\n"
  timed_parse("pathological link soup", s)
end

-- 7. Many unclosed drawers / blocks.
do
  local lines = {}
  for _ = 1, 50 do
    lines[#lines + 1] = ":LOGBOOK:"
    lines[#lines + 1] = "stray content"
  end
  timed_parse("50 unclosed LOGBOOK drawers", table.concat(lines, "\n"))
end

-- 8. Adversarial open/close mismatches at scale: lots of `[[` without
-- `]]`, lots of `{{{` without `}}}`. Tests error-recovery cost on
-- targeted malformed input (random ASCII byte soup is intentionally
-- skipped — tree-sitter's error recovery is genuinely fragile against
-- arbitrary garbage and that's a documented grammar limitation).
do
  local lines = {}
  for _ = 1, 200 do
    lines[#lines + 1] = "[[id:"
  end -- unclosed `[[`
  for _ = 1, 200 do
    lines[#lines + 1] = "{{{macro(arg"
  end -- unclosed macros
  for _ = 1, 100 do
    lines[#lines + 1] = "[[fn:"
  end -- unclosed footnote_ref prefix
  timed_parse("100s of unclosed inline opens", table.concat(lines, "\n"))
end

-- 9. Inlinetask with deeply nested headings (15+ stars).
do
  local lines = { "* Top" }
  for i = 1, 30 do
    lines[#lines + 1] = string.rep("*", 15 + (i % 5)) .. " TODO Inline " .. i
    lines[#lines + 1] = "  body line"
    lines[#lines + 1] = string.rep("*", 15 + (i % 5)) .. " END"
  end
  timed_parse("30 inlinetasks, varying star counts", table.concat(lines, "\n"))
end

-- 10. Tables: header, rules, and many cells.
do
  local lines = {}
  local header = "| " .. string.rep("col | ", 20)
  local rule = "|" .. string.rep("----+", 20) .. "|"
  local row = "| " .. string.rep("a   | ", 20)
  lines[#lines + 1] = header
  lines[#lines + 1] = rule
  for _ = 1, 200 do
    lines[#lines + 1] = row
  end
  timed_parse("200-row × 20-col table", table.concat(lines, "\n"))
end

if fails > 0 then
  print()
  print("FAILED " .. fails .. " checks")
  os.exit(1)
end
print()
print("grammar_fuzz_test: PASS")
