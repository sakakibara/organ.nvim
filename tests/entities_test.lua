-- Verifies organ.entities maps LaTeX names to unicode and applies
-- conceal extmarks on attach.
-- Run via: nvim --headless -l tests/entities_test.lua

local root = vim.fn.getcwd()
dofile(root .. "/tests/_bootstrap.lua")

local ent = require("organ.entities")

assert(ent.lookup("\\alpha") == "α", "alpha lookup")
assert(ent.lookup("\\to") == "→", "to lookup")
assert(ent.lookup("\\sum") == "∑", "sum lookup")
assert(ent.lookup("\\not_a_real_entity") == nil, "unknown returns nil")

-- Extra entities via config.
local organ = require("organ")
organ.config.entities = { extra = { foo = "🦊" } }
ent.refresh()
assert(ent.lookup("\\foo") == "🦊", "extras override")

-- Attach decorates the buffer.
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
  "Math: \\alpha + \\beta = \\gamma",
  "Plain text without entities",
  "Arrow: A \\to B",
})
ent.attach(bufnr)
vim.wait(0) -- drain deferred initial apply

local NS = vim.api.nvim_create_namespace("organ_entities")
local marks = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
local conceals = {}
for _, m in ipairs(marks) do
  local d = m[4]
  if d and d.conceal and d.conceal ~= "" then
    conceals[#conceals + 1] = d.conceal
  end
end
table.sort(conceals)
assert(
  #conceals == 4,
  "expected 4 conceal extmarks (\\alpha, \\beta, \\gamma, \\to), got "
    .. #conceals
    .. ": "
    .. table.concat(conceals, ",")
)
local seen = table.concat(conceals, ",")
assert(seen:find("α", 1, true), "α expected: " .. seen)
assert(seen:find("β", 1, true), "β expected: " .. seen)
assert(seen:find("γ", 1, true), "γ expected: " .. seen)
assert(seen:find("→", 1, true), "→ expected: " .. seen)

io.write("entities ok\n")
os.exit(0)
