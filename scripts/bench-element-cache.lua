-- Compare structure-op cost with vs. without the element cache.
-- Run via: nvim --headless -l scripts/bench-element-cache.lua

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function build_buf(n_headlines, body_lines_each)
  local lines = {}
  for i = 1, n_headlines do
    local level = ((i - 1) % 3) + 1
    lines[#lines + 1] = string.rep("*", level) .. " Headline " .. i
    for j = 1, body_lines_each do
      lines[#lines + 1] = "body line " .. j .. " for " .. i
    end
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b, #lines
end

local b, total = build_buf(500, 10)
io.write(string.format("buffer: %d lines, 500 headlines\n", total))

local function bench(label, n, fn)
  collectgarbage("collect")
  local t0 = vim.uv.hrtime()
  for _ = 1, n do fn() end
  local ms = (vim.uv.hrtime() - t0) / 1e6
  io.write(string.format("  %-50s  %5d run(s)  avg %8.4f ms\n",
    label, n, ms / n))
end

local structure = require("organ.structure")
local ec = require("organ.element_cache")

-- Warm cache.
ec.headlines(b)

bench("structure._find_containing_headline (cached)", 1000, function()
  structure._find_containing_headline(b, total)  -- worst-case: deepest line
end)

bench("structure._subtree_end (cached)", 1000, function()
  structure._subtree_end(b, { line = 1, level = 1 })
end)

-- Force a worst-case rebuild on every call.
bench("element_cache.headlines after invalidation", 200, function()
  ec.invalidate(b)
  ec.headlines(b)
end)

io.write("cache stats: " .. vim.inspect(ec.stats()) .. "\n")
