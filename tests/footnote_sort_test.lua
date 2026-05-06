-- footnote.sort: reorder definitions to match first-reference order;
-- numerics get re-sequenced.
-- Run via: nvim --headless -l tests/footnote_sort_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

require("organ").setup({
  db_path = vim.fn.tempname() .. ".db",
  notify = false,
  scan_on_startup = false,
  debounce_ms = 0,
  watcher = { enabled = false },
})

local fn = require("organ.footnote")

-- Named labels: definitions appear in alphabetical order, references in
-- a different order. After sort, definitions should match reference order.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "First [fn:beta] then [fn:alpha] then [fn:gamma].",
    "",
    "[fn:alpha] alpha body",
    "[fn:beta] beta body",
    "[fn:gamma] gamma body",
  })
  vim.api.nvim_set_current_buf(b)
  local n = fn.sort()
  assert(n == 3, "expected 3 sorted; got " .. tostring(n))
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- Locate the definitions; first def line should be beta, then alpha, then gamma.
  local def_lines = {}
  for _, l in ipairs(lines) do
    local lab = l:match("^%[fn:([%w_%-]+)%]%s")
    if lab then
      def_lines[#def_lines + 1] = lab
    end
  end
  assert(
    table.concat(def_lines, ",") == "beta,alpha,gamma",
    "sorted order: " .. table.concat(def_lines, ",")
  )
end

-- Numeric labels: references in [fn:3] [fn:1] [fn:2] order; after sort
-- definitions reorder AND get renumbered to 1..3 based on the new order.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, {
    "see [fn:3] then [fn:1] then [fn:2].",
    "",
    "[fn:1] one",
    "[fn:2] two",
    "[fn:3] three",
  })
  vim.api.nvim_set_current_buf(b)
  fn.sort()
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  -- After reorder: defs become three, one, two → renumber gives 1, 2, 3.
  -- The bodies remain mapped to their original labels' content; verify the
  -- "three" body lands on `[fn:1]` and so on.
  local body_for = {}
  for _, l in ipairs(lines) do
    local lab, body = l:match("^%[fn:(%d+)%]%s+(.+)$")
    if lab then
      body_for[lab] = body
    end
  end
  assert(body_for["1"] == "three", "first def is now `three`; got " .. tostring(body_for["1"]))
  assert(body_for["2"] == "one", "second def is now `one`; got " .. tostring(body_for["2"]))
  assert(body_for["3"] == "two", "third def is now `two`; got " .. tostring(body_for["3"]))
end

io.write("footnote sort ok\n")
os.exit(0)
