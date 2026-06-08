-- Decoration redraw-path benchmark.
--
-- Measures per-provider wall time on the synchronous decoration
-- dispatch path (the one a single redraw / InsertEnter runs and that
-- cannot be debounced).  Reports on_win + on_line cost per provider so
-- the dominant cost on a heavy buffer is visible rather than guessed.
--
-- Run:
--   nvim --headless -l tests/decoration_frame_bench.lua
--   nvim --headless -l tests/decoration_frame_bench.lua 6000   (lines)

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")
vim.treesitter.language.add("org", { path = require("organ.defaults").parser_path })

require("organ").setup({
  org_dir = "/tmp",
  notify = false,
  scan_on_startup = false,
  watcher = { enabled = false },
  emphasis = { enabled = true },
  stars = { hide = true },
  modern = { bullets = true, blocks = true, pills = true },
})

-- Load every visual provider so the report covers the full stack.
require("organ.conceal")
require("organ.stars")
pcall(require, "organ.description_list")
pcall(require, "organ.fold.contents")
pcall(require, "organ.modern")

local decoration = require("organ.decoration")

local n_lines = tonumber(arg and arg[1]) or 4000

-- Heavy inline content: many emphasis markers, links, and timestamps
-- plus long paragraphs (large org_inline injection trees).
local function build_lines(n)
  local lines = {}
  local sentence = "Some *bold* and /italic/ and _under_ and =verbatim= text "
    .. "with a [[https://example.com][descriptive link]] and a "
    .. "<2026-06-08 Mon 09:00> stamp and [2026-06-09] inactive. "
  while #lines < n do
    local h = #lines % 50
    if h == 0 then
      lines[#lines + 1] = "* Heading " .. #lines
      lines[#lines + 1] = "SCHEDULED: <2026-06-08 Mon> DEADLINE: <2026-06-10 Wed>"
    else
      -- Long paragraph lines maximise injection-tree size.
      lines[#lines + 1] = sentence:rep(3)
    end
  end
  return lines
end

local bufnr = vim.api.nvim_create_buf(false, true)
vim.bo[bufnr].filetype = "org"
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, build_lines(n_lines))

local winid = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(winid, bufnr)
vim.wo[winid].conceallevel = 2

decoration.attach(bufnr)

local profile = require("organ.profile")
profile.start({ slow_ms = 1000000 }) -- enable frame timing; suppress slow-example spam

-- Warm + simulate one screenful redrawn FRAMES times, as a scroll/insert
-- would.  topline 0, a 50-row viewport (a typical screen).
local FRAMES = 30
local top, bot = 0, math.min(n_lines - 1, 49)

decoration.get_tree(bufnr) -- first parse (recorded as frame.parse)
local t0 = vim.uv.hrtime()
for _ = 1, FRAMES do
  -- Force a re-parse path each frame by bumping nothing (cached) -- this
  -- mirrors scrolling, where the tree is cached and only dispatch runs.
  decoration._dispatch_on_win(0, winid, bufnr, top, bot)
  for row = top, bot do
    decoration._dispatch_on_line(0, winid, bufnr, row)
  end
end
local total_ms = (vim.uv.hrtime() - t0) / 1e6

print(string.format("\nlines=%d  viewport=%d rows  frames=%d", n_lines, bot - top + 1, FRAMES))
print(
  string.format("total dispatch wall time: %.1f ms  (%.2f ms/frame)\n", total_ms, total_ms / FRAMES)
)
profile.report()
